export function preparationLimit(env = process.env) {
    const value = Number(env.WEBVIEW_PREPARATION_CONCURRENCY ?? 4);
    if (!Number.isInteger(value) || value < 1 || value > 32)
        throw new Error('Invalid WEBVIEW_PREPARATION_CONCURRENCY');
    return value;
}
export function blockedDestinations(stderr) {
    const entries = [];
    const seen = new Set();
    for (const line of stderr.split(/\r?\n/)) {
        if (!line.startsWith('ORACLE_TASK_DESTINATION_BLOCKED ') || line.length > 1024)
            continue;
        try {
            const { hostname, code } = JSON.parse(line.slice('ORACLE_TASK_DESTINATION_BLOCKED '.length));
            if (typeof hostname !== 'string' || !/^(?:[a-z0-9.-]{1,253}|\[[0-9a-f:.]{2,45}\])$/i.test(hostname) ||
                typeof code !== 'string' || !/^(TASK_DESTINATION_FORBIDDEN|TASK_URL_FORBIDDEN|TASK_PORT_FORBIDDEN)$/.test(code))
                continue;
            const key = `${hostname}:${code}`;
            if (seen.has(key))
                continue;
            seen.add(key);
            entries.push({ hostname, code });
            if (entries.length === 8)
                break;
        }
        catch { /* Ignore unrelated or malformed child output. */ }
    }
    return entries;
}
export function createPreparationRunner(options) {
    if (!Number.isInteger(options.limit) || options.limit < 1 || options.limit > 32)
        throw new Error('Invalid preparation limit');
    const emit = (entry) => { try {
        options.emit(entry);
    }
    catch { /* Audit failure must not release running work. */ } };
    let reserved = 0;
    return async (factory) => {
        if (reserved >= options.limit) {
            emit({ schema: 'oracle.audit.v1', timestamp: new Date().toISOString(), event: 'preparation_capacity_rejected', code: 'PREPARATION_CAPACITY' });
            throw new Error('PREPARATION_CAPACITY');
        }
        reserved++;
        try {
            const child = await factory();
            options.started?.(child);
            return await new Promise((resolve, reject) => {
                let stdout = '', stderr = '';
                let failure;
                let outputBytes = 0;
                const timer = setTimeout(() => { failure = new Error('PREPARATION_TIMEOUT'); options.terminate(child, 'timeout'); }, options.timeoutMs());
                const collect = (stream, chunk) => {
                    const text = String(chunk);
                    outputBytes += Buffer.byteLength(text);
                    if (outputBytes > 1_000_000) {
                        failure ??= new Error('PREPARATION_OUTPUT_LIMIT');
                        options.terminate(child, 'output_limit');
                        return;
                    }
                    if (stream === 'stdout')
                        stdout += text;
                    else
                        stderr += text;
                };
                child.stdout?.on('data', chunk => collect('stdout', chunk));
                child.stderr?.on('data', chunk => collect('stderr', chunk));
                // A kill error is not process exit. Hold the reservation until close.
                child.on('error', error => { failure = error; });
                child.once('close', exitCode => {
                    clearTimeout(timer);
                    options.closed?.(child);
                    for (const entry of blockedDestinations(stderr))
                        emit({ schema: 'oracle.audit.v1', timestamp: new Date().toISOString(), event: 'task_destination_blocked', ...entry });
                    if (failure)
                        reject(failure);
                    else
                        resolve({ stdout, stderr, exitCode });
                });
            });
        }
        finally {
            reserved--;
        }
    };
}
