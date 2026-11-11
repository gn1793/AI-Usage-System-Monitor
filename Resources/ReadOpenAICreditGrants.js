// Read the user's existing Brave tab. Never read cookies, tokens or other tabs' content.
function run() {
    const browser = Application('com.brave.Browser');
    const target = 'https://platform.openai.com/settings/organization/billing/credit-grants';
    if (!browser.running()) return JSON.stringify({error: 'browser_not_running'});
    const extract = `(function () {
        if (location.origin !== 'https://platform.openai.com' || location.pathname.split('/').filter(Boolean).join('/') !== 'settings/organization/billing/credit-grants') return {error: 'login_required'};
        const expected = ['RECEIVED', 'STATE', 'BALANCE', 'EXPIRES'];
        const table = Array.from(document.querySelectorAll('table')).find(table => {
            const headers = Array.from(table.querySelectorAll('thead th')).map(cell => cell.innerText.trim().toUpperCase());
            return expected.every((header, index) => headers[index] === header);
        });
        if (!table) return {error: 'table_not_ready'};
        if (!/\\bUSD\\b/.test(document.body.innerText)) return {error: 'unsupported_currency'};
        const rows = Array.from(table.querySelectorAll('tbody tr')).map(row => Array.from(row.querySelectorAll('td')).map(cell => cell.innerText.trim()));
        return {currency: 'USD', rows: rows, capturedAt: new Date().toISOString()};
    })()`;
    try {
        const matches = [];
        for (const window of browser.windows()) {
            for (const tab of window.tabs()) {
                const url = tab.url();
                if (url && url.split(/[?#]/)[0].replace(/\/$/, '') === target) matches.push(tab);
            }
        }
        if (!matches.length) return JSON.stringify({error: 'tab_missing'});
        const active = browser.windows[0].activeTab();
        const selected = matches.find(tab => tab.id() === active.id());
        if (matches.length > 1 && !selected) return JSON.stringify({error: 'multiple_tabs'});
        const tab = selected || matches[0];
        // Check the browser's scripting permission before changing the page.
        tab.execute({javascript: 'true'});
        tab.reload();
        const deadline = Date.now() + 20000;
        while (Date.now() < deadline) {
            delay(0.3);
            const url = tab.url();
            if (!url || url.split(/[?#]/)[0].replace(/\/$/, '') !== target) return JSON.stringify({error: 'login_required'});
            if (tab.loading()) continue;
            const result = tab.execute({javascript: 'JSON.stringify(' + extract + ')'});
            if (!result) continue;
            const payload = JSON.parse(result);
            if (payload.error === 'table_not_ready') continue;
            return JSON.stringify(payload);
        }
        return JSON.stringify({error: 'table_not_ready'});
    } catch (error) {
        const message = String(error);
        if (error.errorNumber === -1743 || /not authorized|not permitted|권한|승인/.test(message)) return JSON.stringify({error: 'automation_denied'});
        if (/javascript|자바스크립트/i.test(message)) return JSON.stringify({error: 'javascript_disabled'});
        return JSON.stringify({error: 'browser_error'});
    }
}
