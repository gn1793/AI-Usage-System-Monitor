#!/usr/bin/env python3
"""Portable JSONL metrics collector. Linux /proc and NVIDIA NVML; other OS GPU-only when available.
System metrics use standard libraries; GPU metrics require pynvml (nvidia-ml-py).
"""
import glob, json, math, os, platform, select, sys, time, traceback
from datetime import datetime, timezone

VERSION=1

def emit(obj):
    sys.stdout.write(json.dumps(obj,ensure_ascii=False,separators=(',',':'))+'\n');sys.stdout.flush()

def read_file(path):
    try:
        with open(path,'r') as f:return f.read()
    except (OSError,UnicodeError): return None

def linux_cpu():
    s=read_file('/proc/stat')
    if not s:return None
    rows={}
    for line in s.splitlines():
        parts=line.split()
        if not parts or not parts[0].startswith('cpu'):continue
        try:
            vals=list(map(int,parts[1:]))
            # guest/guest_nice are already included in user/nice
            total=sum(vals[:8]);idle=vals[3]+(vals[4] if len(vals)>4 else 0)
            rows[parts[0]]=(total,idle)
        except (ValueError,IndexError): pass
    return rows

def cpu_rates(old,new):
    if not old or not new:return None,[]
    def rate(key):
        if key not in old or key not in new:return None
        t=new[key][0]-old[key][0];i=new[key][1]-old[key][1]
        return round(max(0,min(100,100*(1-i/t))),1) if t>0 else None
    keys=sorted((k for k in new if k!='cpu'),key=lambda k:int(k[3:]) if k[3:].isdigit() else 999999)
    return rate('cpu'),[rate(k) for k in keys]

def linux_ram():
    s=read_file('/proc/meminfo')
    if not s:return None
    d={}
    for ln in s.splitlines():
        try:
            k,v=ln.split(':',1);d[k]=int(v.split()[0])*1024
        except (ValueError,IndexError):continue
    total=d.get('MemTotal');available=d.get('MemAvailable',d.get('MemFree'))
    if total is None or available is None:return None
    return dict(total_bytes=total,used_bytes=max(0,total-available),available_bytes=available)

def cpu_name():
    if platform.system()!='Linux':return platform.processor() or platform.machine()
    s=read_file('/proc/cpuinfo') or ''
    for line in s.splitlines():
        if line.startswith(('model name','Hardware','Processor')) and ':' in line:
            return line.split(':',1)[1].strip()
    return platform.processor() or platform.machine()

class CPUTemperatureSampler:
    def __init__(self):
        self.sensors = []
        self.next_discovery = 0

    def read(self):
        now = time.monotonic()
        if now >= self.next_discovery:
            candidates = []
            for path in glob.glob('/sys/class/hwmon/hwmon*'):
                chip = (read_file(path+'/name') or '').strip()
                if chip not in ('k10temp', 'coretemp', 'zenpower'):
                    continue
                for sensor in glob.glob(path+'/temp*_input'):
                    label = (read_file(sensor.replace('_input', '_label')) or '').strip().lower()
                    priority = 2 if 'package' in label or 'tdie' in label else 1 if 'tctl' in label or not label else 0
                    if priority:
                        candidates.append((priority, sensor))
            best = max((priority for priority, _ in candidates), default=0)
            self.sensors = [sensor for priority, sensor in candidates if priority == best]
            self.next_discovery = now + 60
        values = []
        for sensor in self.sensors:
            try:
                value = float((read_file(sensor) or '').strip()) / 1000
                if -20 < value < 130:
                    values.append(value)
            except ValueError:
                pass
        return max(values) if values else None


class GPUSampler:
    def __init__(self):
        self.nvml = None
        self.handles = []
        self.metadata = []
        self.error = None
        self.next_retry = 0
        self.initialize()

    def initialize(self):
        self.next_retry = time.monotonic() + 60
        try:
            import pynvml as nv
            nv.nvmlInit()
            self.nvml = nv
            self.handles = [nv.nvmlDeviceGetHandleByIndex(i) for i in range(nv.nvmlDeviceGetCount())]
            self.metadata = []
            for i, handle in enumerate(self.handles):
                def text(fn, fallback):
                    try:
                        value = fn()
                        return value.decode(errors='replace') if isinstance(value, bytes) else str(value)
                    except Exception:
                        return fallback
                self.metadata.append(dict(index=i,
                    uuid=text(lambda: nv.nvmlDeviceGetUUID(handle), 'gpu-'+str(i)),
                    name=text(lambda: nv.nvmlDeviceGetName(handle), 'NVIDIA GPU')))
            self.error = None
        except Exception as error:
            self.error = str(error)[:480]
            self.close()
            self.handles = []
            self.metadata = []

    def read(self):
        if (self.nvml is None or self.error) and time.monotonic() >= self.next_retry:
            self.close()
            self.initialize()
        if self.nvml is None:
            return []
        result, errors = [], []
        nv = self.nvml
        for i, handle in enumerate(self.handles):
            try:
                memory = nv.nvmlDeviceGetMemoryInfo(handle)
                def optional(fn):
                    try:
                        return fn()
                    except Exception:
                        return None
                result.append(dict(self.metadata[i], memory_used_bytes=memory.used,
                    memory_free_bytes=memory.free, memory_total_bytes=memory.total,
                    utilization_percent=optional(lambda: nv.nvmlDeviceGetUtilizationRates(handle).gpu),
                    temperature_c=optional(lambda: nv.nvmlDeviceGetTemperature(handle, nv.NVML_TEMPERATURE_GPU))))
            except Exception as error:
                errors.append('GPU '+str(i)+': '+str(error))
        self.error = ' | '.join(errors)[:480] or None
        return result

    def close(self):
        if self.nvml:
            try:
                self.nvml.nvmlShutdown()
            except Exception:
                pass
            self.nvml = None


def run():
    interval, sequence = 10.0, 0
    linux = platform.system() == 'Linux'
    old = linux_cpu() if linux else None
    gpu = GPUSampler()
    temperature = CPUTemperatureSampler()
    model, hostname, system = cpu_name(), platform.node(), platform.system()
    next_at = time.monotonic() + 1
    pending = bytearray()
    running = True
    emit(dict(protocol_version=VERSION, type='hello', os=system, hostname=hostname,
              gpu_backend='nvml' if gpu.nvml else 'unavailable', gpu_error=gpu.error))
    try:
        while running:
            ready, _, _ = select.select([sys.stdin.fileno()], [], [], max(0, next_at-time.monotonic()))
            if ready:
                # TextIOWrapper may read ahead beyond the kernel's ready bytes.
                # Own the raw byte buffer and drain every complete JSONL command.
                chunk = os.read(sys.stdin.fileno(), 65536)
                if not chunk:
                    break
                pending.extend(chunk)
                if len(pending) > 100000:
                    pending.clear()
                    emit(dict(protocol_version=VERSION, type='error', message='command too large'))
                while b'\n' in pending:
                    line, _, remaining = pending.partition(b'\n')
                    pending[:] = remaining
                    try:
                        command = json.loads(line)
                        if not isinstance(command, dict):
                            raise ValueError('invalid command')
                        action = command.get('command')
                        if action == 'shutdown':
                            running = False
                            break
                        if action == 'set_interval':
                            seconds = float(command['seconds'])
                            if not math.isfinite(seconds) or not 1 <= seconds <= 3600:
                                raise ValueError('invalid interval')
                            interval = seconds
                            deadline = time.monotonic() + interval
                            next_at = min(next_at, deadline) if sequence == 0 else deadline
                            emit(dict(protocol_version=VERSION, type='ack', command='set_interval', seconds=interval))
                        elif action == 'refresh':
                            next_at = time.monotonic()
                        else:
                            raise ValueError('unknown command')
                    except (ValueError, KeyError, TypeError, UnicodeError):
                        emit(dict(protocol_version=VERSION, type='error', message='invalid command'))
            if not running:
                break
            if time.monotonic() < next_at:
                continue
            current = linux_cpu() if linux else None
            usage, cores = cpu_rates(old, current)
            old = current
            sequence += 1
            gpus = gpu.read()
            emit(dict(protocol_version=VERSION, type='snapshot', sequence=sequence,
                timestamp=datetime.now(timezone.utc).isoformat(), host=dict(hostname=hostname, os=system),
                cpu=dict(model=model, usage_percent=usage, temperature_c=temperature.read() if linux else None, logical_core_usage=cores),
                ram=linux_ram() if linux else None, gpus=gpus,
                gpu_backend='nvml' if gpu.nvml else 'unavailable', gpu_error=gpu.error,
                gpu_detected_count=len(gpu.handles), errors=[gpu.error] if gpu.error else []))
            next_at = time.monotonic() + interval
    finally:
        gpu.close()

if __name__ == '__main__':
    try:
        run()
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
