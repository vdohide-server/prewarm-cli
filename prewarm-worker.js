#!/usr/bin/env node
// ============================================
// Prewarm Worker - Node.js + Axios Version
// ============================================

// Try to load axios from multiple locations
let axios;
try {
    axios = require('axios');
} catch (e) {
    try {
        axios = require('/usr/local/bin/node_modules/axios');
    } catch (e2) {
        try {
            axios = require('/usr/local/lib/node_modules/axios');
        } catch (e3) {
            console.error('ERROR: axios not found. Run: sudo npm install -g axios');
            process.exit(1);
        }
    }
}

const fs = require('fs');
const path = require('path');
const { URL } = require('url');

// Arguments
const JOB_ID = process.argv[2];
const MASTER_URL = process.argv[3];
const PARALLEL = parseInt(process.argv[4] || '10', 10);

// Paths
const PREWARM_DIR = '/var/lib/prewarm';
const RUNNING_DIR = `${PREWARM_DIR}/running`;
const JOB_FILE = `${RUNNING_DIR}/${JOB_ID}.job`;

// Configuration
const TIMEOUT = 10000;
const HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
};

// Stats
let stats = {
    total: 0,
    progress: 0,
    hit: 0,
    miss: 0,
    expired: 0,
    failed: 0
};

// Logging
function log(msg) {
    const time = new Date().toTimeString().slice(0, 8);
    console.log(`[${time}] ${msg}`);
}

// Update job file
function updateJob() {
    if (!fs.existsSync(JOB_FILE)) return;
    
    try {
        let content = fs.readFileSync(JOB_FILE, 'utf8');
        content = content.replace(/"progress": \d+/, `"progress": ${stats.progress}`);
        content = content.replace(/"total": \d+/, `"total": ${stats.total}`);
        content = content.replace(/"hit": \d+/, `"hit": ${stats.hit}`);
        content = content.replace(/"miss": \d+/, `"miss": ${stats.miss}`);
        content = content.replace(/"expired": \d+/, `"expired": ${stats.expired}`);
        content = content.replace(/"failed": \d+/, `"failed": ${stats.failed}`);
        fs.writeFileSync(JOB_FILE, content);
    } catch (e) {
        // Ignore errors
    }
}

// HEAD request using axios
async function headRequest(url) {
    const startTime = Date.now();
    try {
        const res = await axios.head(url, {
            headers: HEADERS,
            timeout: TIMEOUT,
            validateStatus: () => true
        });
        const elapsed = Date.now() - startTime;
        return {
            url,
            code: res.status,
            cache: res.headers['cf-cache-status'] || 'NONE',
            pop: (res.headers['cf-ray'] || '').split('-')[1] || 'UNK',
            time: elapsed
        };
    } catch (e) {
        return {
            url,
            code: 0,
            cache: 'ERR',
            pop: 'UNK',
            time: Date.now() - startTime
        };
    }
}

// Fetch URL content (for playlists)
async function fetchContent(url) {
    const res = await axios.get(url, {
        headers: HEADERS,
        timeout: TIMEOUT
    });
    return res.data;
}

// Build full URL
function buildUrl(segment, baseUrl) {
    if (segment.startsWith('http')) return segment;
    if (segment.startsWith('//')) return 'https:' + segment;
    if (segment.startsWith('/')) {
        const u = new URL(baseUrl);
        return u.origin + segment;
    }
    return new URL(segment, baseUrl).href;
}

// Parse HLS playlist and collect URLs
async function collectUrls(masterUrl) {
    const urls = new Set([masterUrl]);
    const variants = new Set();
    
    try {
        const master = await fetchContent(masterUrl);
        const baseUrl = masterUrl.substring(0, masterUrl.lastIndexOf('/') + 1);
        
        // Find child playlists
        const lines = master.split('\n');
        const childPlaylists = lines.filter(l => l.trim() && !l.startsWith('#') && l.endsWith('.m3u8'));
        
        if (childPlaylists.length > 0) {
            // Multi-variant playlist
            for (const child of childPlaylists) {
                const childUrl = buildUrl(child.trim(), baseUrl);
                urls.add(childUrl);
                
                // Extract variant name
                const match = childUrl.match(/\/([^\/]+)\/[^\/]+\.m3u8$/);
                if (match) variants.add(match[1]);
                
                try {
                    const childContent = await fetchContent(childUrl);
                    const childBase = childUrl.substring(0, childUrl.lastIndexOf('/') + 1);
                    const segments = childContent.split('\n')
                        .filter(l => l.trim() && !l.startsWith('#') && (l.endsWith('.ts') || l.endsWith('.jpeg') || l.startsWith('http')));
                    
                    for (const seg of segments) {
                        urls.add(buildUrl(seg.trim(), childBase));
                    }
                } catch (e) {
                    // Ignore child fetch errors
                }
            }
        } else {
            // Single playlist
            const segments = lines.filter(l => l.trim() && !l.startsWith('#') && (l.endsWith('.ts') || l.endsWith('.jpeg') || l.startsWith('http')));
            for (const seg of segments) {
                urls.add(buildUrl(seg.trim(), baseUrl));
            }
        }
    } catch (e) {
        log(`ERROR: Failed to fetch master playlist: ${e.message}`);
        process.exit(1);
    }
    
    return { urls: Array.from(urls), variants: Array.from(variants) };
}

// Process URLs with controlled concurrency
async function processUrls(urls) {
    const queue = [...urls];
    const active = new Set();
    
    async function processOne(url) {
        const result = await headRequest(url);
        stats.progress++;
        
        // Extract variant
        const match = url.match(/\/([^\/]+)\/[^\/]+\.(ts|jpeg|m3u8)$/);
        const variant = match ? match[1] : 'master';
        
        if (result.code === 200 || result.code === 206) {
            if (result.cache === 'HIT') stats.hit++;
            else if (result.cache === 'MISS') stats.miss++;
            else if (result.cache === 'EXPIRED') stats.expired++;
            
            console.log(`✓ ${result.code} | ${result.cache} | ${result.pop} | ${result.time}ms | ${variant} | ${path.basename(url)}`);
        } else {
            stats.failed++;
            console.log(`✗ ${result.code || 'ERR'} | ${result.cache} | ${result.pop} | ${result.time}ms | ${variant} | ${path.basename(url)}`);
        }
    }
    
    // Process with concurrency limit
    while (queue.length > 0 || active.size > 0) {
        // Start new requests up to PARALLEL limit
        while (queue.length > 0 && active.size < PARALLEL) {
            const url = queue.shift();
            const promise = processOne(url).then(() => {
                active.delete(promise);
            });
            active.add(promise);
        }
        
        // Wait for at least one to complete
        if (active.size > 0) {
            await Promise.race(active);
        }
    }
}

// Progress updater
let progressInterval;
function startProgressUpdater() {
    progressInterval = setInterval(() => {
        updateJob();
    }, 3000);
}

function stopProgressUpdater() {
    if (progressInterval) {
        clearInterval(progressInterval);
        updateJob(); // Final update
    }
}

// Main
async function main() {
    log(`Starting prewarm: ${MASTER_URL} (parallel: ${PARALLEL})`);
    
    // Collect URLs
    const { urls, variants } = await collectUrls(MASTER_URL);
    stats.total = urls.length;
    
    log(`Found ${urls.length} unique URLs`);
    log(`Variants: ${variants.length > 0 ? variants.join(', ') : 'none'}`);
    
    updateJob();
    startProgressUpdater();
    
    // Process
    log(`Pre-warming with ${PARALLEL} parallel connections...`);
    await processUrls(urls);
    
    stopProgressUpdater();
    
    // Summary
    log('');
    log('==========================================');
    log(`Summary: ${stats.total} total | HIT ${stats.hit} | MISS ${stats.miss} | EXPIRED ${stats.expired} | FAILED ${stats.failed}`);
    if (stats.total > 0) {
        const hitRate = ((stats.hit / stats.total) * 100).toFixed(1);
        log(`Hit Rate: ${hitRate}%`);
    }
    log('==========================================');
    log('Completed!');
}

main().catch(e => {
    log(`ERROR: ${e.message}`);
    process.exit(1);
});
