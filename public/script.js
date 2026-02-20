let autoRefreshInterval = null;

const DEBUG = new URLSearchParams(window.location.search).get('debug') === '1';

function debugLog(message, data) {
    if (DEBUG) {
        console.log(`[JobEfficiency Debug] ${message}`, data || '');
    }
}

document.addEventListener('DOMContentLoaded', () => {
    initializeEventListeners();
    loadJobEfficiency();
    setupAutoRefresh();
});

function initializeEventListeners() {
    document.getElementById('refresh-btn').addEventListener('click', () => {
        loadJobEfficiency();
    });

    document.getElementById('efficiency-state-filter').addEventListener('change', () => {
        loadJobEfficiency();
    });
}

function setupAutoRefresh() {
    clearInterval(autoRefreshInterval);
    autoRefreshInterval = setInterval(() => {
        loadJobEfficiency();
    }, 30000);
}

async function loadJobEfficiency() {
    try {
        debugLog('Fetching job efficiency summary...');
        const stateFilter = document.getElementById('efficiency-state-filter')?.value || 'total';
        const response = await fetch(
            `${window.APP_BASE_PATH}/api/job-efficiency-summary?state_filter=${encodeURIComponent(stateFilter)}`
        );
        const result = await response.json();

        if (result.success) {
            renderJobEfficiencySummary(result.data || {});
            updateLastUpdateTime();
        } else {
            throw new Error(result.error || 'Failed to load efficiency summary');
        }
    } catch (error) {
        console.error('Failed to load job efficiency summary:', error);
        renderEfficiencyError(error.message);
    }
}

function renderEfficiencyError(message) {
    ['efficiency-7-days', 'efficiency-30-days'].forEach(id => {
        const el = document.getElementById(id);
        if (el) {
            el.innerHTML = `
                <h3>${id.includes('7') ? 'Last 7 Days' : 'Last 30 Days'}</h3>
                <div class="text-muted">Unable to load efficiency metrics: ${escapeHtml(message)}</div>
            `;
        }
    });
}

function renderJobEfficiencySummary(summary) {
    const intro = document.getElementById('efficiency-intro-text');
    if (intro) {
        if (summary.state_filter === 'completed') {
            intro.textContent = 'Requested resource summary for completed jobs. Use this to right-size CPU, memory, GPU, and walltime requests.';
        } else {
            intro.textContent = 'Requested resource summary for all states in the selected window.';
        }
    }

    renderEfficiencyWindow('efficiency-7-days', 'Last 7 Days', summary.last_7_days);
    renderEfficiencyWindow('efficiency-30-days', 'Last 30 Days', summary.last_30_days);
}

function renderEfficiencyWindow(elementId, title, data) {
    const el = document.getElementById(elementId);
    if (!el) return;

    const jobs = data?.jobs_considered || 0;
    const requestedCpu = data?.requested_cpu || {};
    const requestedGpu = data?.requested_gpu || {};
    const requestedMemory = data?.requested_memory || {};
    const requestedRuntime = data?.requested_runtime || {};
    const cpu = data?.cpu || {};
    const memory = data?.memory || {};
    const runtime = data?.runtime || {};

    el.innerHTML = `
        <h3>${title}</h3>
        <div class="efficiency-count">${jobs} jobs analyzed</div>
        <table class="efficiency-table">
            <thead>
                <tr>
                    <th>Metric</th>
                    <th>Min</th>
                    <th>Median</th>
                    <th>Max</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td>Requested CPUs</td>
                    <td>${formatNumber(requestedCpu.min, 0)}</td>
                    <td>${formatNumber(requestedCpu.median, 0)}</td>
                    <td>${formatNumber(requestedCpu.max, 0)}</td>
                </tr>
                <tr>
                    <td>Requested GPUs</td>
                    <td>${formatNumber(requestedGpu.min, 0)}</td>
                    <td>${formatNumber(requestedGpu.median, 0)}</td>
                    <td>${formatNumber(requestedGpu.max, 0)}</td>
                </tr>
                <tr>
                    <td>Requested Memory</td>
                    <td>${formatBytes(requestedMemory.min)}</td>
                    <td>${formatBytes(requestedMemory.median)}</td>
                    <td>${formatBytes(requestedMemory.max)}</td>
                </tr>
                <tr>
                    <td>Requested Runtime</td>
                    <td>${formatDuration(requestedRuntime.min)}</td>
                    <td>${formatDuration(requestedRuntime.median)}</td>
                    <td>${formatDuration(requestedRuntime.max)}</td>
                </tr>
            </tbody>
        </table>
        <div class="efficiency-memory-stats">
            <strong>Max memory used:</strong> ${formatBytes(memory.max_used_bytes)}
            <span class="efficiency-divider">|</span>
            <strong>Average memory used:</strong> ${formatBytes(memory.avg_used_bytes)}
        </div>
        <div class="efficiency-distributions">
            <h4>CPU Allocation Efficiency Distribution</h4>
            ${renderDistributionBars(cpu.buckets || {})}
            <h4>Memory Efficiency Distribution</h4>
            ${renderDistributionBars(memory.buckets || {})}
            <h4>Walltime Usage Distribution</h4>
            ${renderDistributionBars(runtime.buckets || {})}
        </div>
        <div class="efficiency-guidance">
            ${renderEfficiencyGuidance(cpu.mean, memory.mean, runtime.mean)}
        </div>
    `;
}

function renderDistributionBars(buckets) {
    const entries = Object.entries(buckets);
    const total = entries.reduce((sum, [, count]) => sum + count, 0);

    if (!entries.length || total === 0) {
        return '<div class="text-muted">No distribution data available</div>';
    }

    return entries.map(([label, count]) => {
        const pct = (count / total) * 100;
        return `
            <div class="distribution-row">
                <span class="distribution-label">${escapeHtml(label)}</span>
                <div class="distribution-track">
                    <div class="distribution-fill" style="width:${pct.toFixed(1)}%"></div>
                </div>
                <span class="distribution-value">${count}</span>
            </div>
        `;
    }).join('');
}

function renderEfficiencyGuidance(cpuMean, memMean, runtimeMean) {
    const tips = [];

    if (cpuMean !== null && cpuMean !== undefined) {
        if (cpuMean < 50) tips.push('CPU allocation efficiency is low. Consider requesting fewer cores.');
        if (cpuMean > 95) tips.push('CPU usage is near allocation limits. More cores may improve throughput.');
    }
    if (memMean !== null && memMean !== undefined) {
        if (memMean < 50) tips.push('Memory usage is low on average. You may be over-requesting memory.');
        if (memMean > 90) tips.push('Memory usage is close to requested limits. Add memory headroom.');
    }
    if (runtimeMean !== null && runtimeMean !== undefined) {
        if (runtimeMean < 60) tips.push('Most jobs finish well before walltime. Shorter walltimes can improve scheduling.');
        if (runtimeMean > 90) tips.push('Jobs use most of requested walltime. Increase walltime to reduce timeout risk.');
    }

    if (!tips.length) {
        return '<div class="text-muted">Efficiency trends look balanced for the selected window.</div>';
    }

    return tips.map(tip => `<div>${escapeHtml(tip)}</div>`).join('');
}

function updateLastUpdateTime() {
    const now = new Date();
    document.getElementById('last-update-time').textContent = now.toLocaleTimeString();
}

function formatBytes(bytes) {
    if (!bytes || bytes <= 0) return 'N/A';
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    let value = Number(bytes);
    let idx = 0;
    while (value >= 1024 && idx < units.length - 1) {
        value /= 1024;
        idx += 1;
    }
    return `${value.toFixed(value >= 100 ? 0 : 1)} ${units[idx]}`;
}

function formatNumber(value, decimals = 0) {
    if (value === null || value === undefined || Number.isNaN(Number(value))) return 'N/A';
    return Number(value).toFixed(decimals);
}

function formatDuration(seconds) {
    if (seconds === null || seconds === undefined || Number.isNaN(Number(seconds)) || Number(seconds) <= 0) return 'N/A';
    let totalMinutes = Math.round(Number(seconds) / 60);
    const days = Math.floor(totalMinutes / (24 * 60));
    totalMinutes %= (24 * 60);
    const hours = Math.floor(totalMinutes / 60);
    const minutes = totalMinutes % 60;

    return `${days}d ${hours}h ${minutes}m`;
}

function escapeHtml(text) {
    if (text === null || text === undefined) return '';
    const div = document.createElement('div');
    div.textContent = text.toString();
    return div.innerHTML;
}
