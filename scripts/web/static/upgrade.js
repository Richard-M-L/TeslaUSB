// Online upgrade — check for updates and trigger git pull + web restart.
(function() {
    var _pollTimer = null;
    var _checkRunning = false;

    // ── Helpers ──
    function el(id) { return document.getElementById(id); }

    function escapeHTML(s) {
        return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;')
                       .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    }

    function resetBtn() {
        var btn = el('btnUpgradeCheck');
        if (!btn) return;
        btn.textContent = _t('index.upgrade_check_btn');
        btn.className = 'btn btn-secondary';
        btn.style.padding = '8px 20px';
        btn.onclick = checkUpgrade;
        btn.disabled = false;
    }

    // ── Check for updates ──
    window.checkUpgrade = function() {
        if (_checkRunning) return;
        _checkRunning = true;
        var btn = el('btnUpgradeCheck');
        var msg = el('upgradeMsg');
        if (!btn) return;
        btn.disabled = true;
        btn.textContent = _t('index.upgrade_checking');
        if (msg) msg.innerHTML = '';
        fetch('/api/system/upgrade/check', { method: 'POST' })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                _checkRunning = false;
                if (data.error) {
                    if (msg) msg.innerHTML = '<span style="color:var(--ds-accent-warning)">' +
                        _t('index.upgrade_check_error') + '</span>';
                    btn.textContent = _t('index.upgrade_check_btn');
                    btn.disabled = false;
                    return;
                }
                if (!data.available) {
                    if (msg) msg.innerHTML = '<span style="color:var(--ds-accent-success)">' +
                        _t('index.upgrade_uptodate') + '</span>';
                    btn.textContent = _t('index.upgrade_check_btn');
                    btn.disabled = false;
                    return;
                }
                if (msg) msg.innerHTML = '<span style="color:var(--ds-accent-primary)">' +
                    _t('index.upgrade_available') + '</span> ';
                btn.textContent = _t('index.upgrade_now_btn');
                btn.className = 'btn btn-primary';
                btn.style.padding = '8px 20px';
                btn.onclick = runUpgrade;
                btn.disabled = false;
            })
            .catch(function() {
                _checkRunning = false;
                if (msg) msg.innerHTML = '<span style="color:var(--ds-accent-warning)">' +
                    _t('index.upgrade_check_error') + '</span>';
                btn.textContent = _t('index.upgrade_check_btn');
                btn.disabled = false;
            });
    };

    // ── Trigger upgrade ──
    function runUpgrade() {
        var btn = el('btnUpgradeCheck');
        var msg = el('upgradeMsg');
        if (!btn) return;
        btn.disabled = true;
        btn.textContent = _t('index.upgrade_upgrading');
        fetch('/api/system/upgrade', { method: 'POST' })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (!data.ok) {
                    if (msg) msg.innerHTML = '<span style="color:var(--ds-accent-danger)">' +
                        _t('index.upgrade_error') + ': ' + escapeHTML(data.error || '') + '</span>';
                    resetBtn();
                    return;
                }
                pollStatus(0);
            })
            .catch(function() {
                if (msg) msg.innerHTML = '<span style="color:var(--ds-accent-danger)">' +
                    _t('index.upgrade_error') + '</span>';
                resetBtn();
            });
    }

    // ── Poll upgrade status ──
    function pollStatus(attempt) {
        if (attempt > 120) {
            var msg = el('upgradeMsg');
            if (msg) msg.innerHTML = '<span style="color:var(--ds-accent-danger)">' +
                _t('index.upgrade_error') + ' (timeout)</span>';
            resetBtn();
            return;
        }
        fetch('/api/system/upgrade/status')
            .then(function(r) { return r.json(); })
            .then(function(data) {
                var msg = el('upgradeMsg');
                var phase = data.phase || '';

                if (phase === 'done') {
                    if (data.code === 3) {
                        if (msg) msg.innerHTML = '<span style="color:var(--ds-accent-warning);white-space:pre-line">' +
                            _t('index.upgrade_done_system') + '</span>';
                    } else {
                        if (msg) msg.innerHTML = '<span style="color:var(--ds-accent-success)">' +
                            _t('index.upgrade_done') + '</span>';
                    }
                    resetBtn();
                    return;
                }

                if (phase === 'error') {
                    if (msg) msg.innerHTML = '<span style="color:var(--ds-accent-danger)">' +
                        _t('index.upgrade_error') + ': ' + escapeHTML(data.message || '') + '</span>';
                    resetBtn();
                    return;
                }

                if (msg) msg.innerHTML = '<span style="color:var(--text-secondary)">' +
                    escapeHTML(data.message || _t('index.upgrade_upgrading')) +
                    ' (' + (data.pct || 0) + '%)</span>';
                _pollTimer = setTimeout(function() { pollStatus(attempt + 1); }, 1000);
            })
            .catch(function() {
                _pollTimer = setTimeout(function() { pollStatus(attempt + 1); }, 2000);
            });
    }
})();
