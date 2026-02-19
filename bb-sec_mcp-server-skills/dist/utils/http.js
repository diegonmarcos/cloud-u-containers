import { exec } from "./exec.js";
import { RUST_API_MESH, RUST_API_PUBLIC, AUTHELIA_TOKEN_PATH } from "./paths.js";
import { readFileSync } from "fs";
function httpRequest(method, url, body, timeout, extraHeaders) {
    const args = [
        "-s", "-S",
        "-X", method,
        "-H", "Content-Type: application/json",
        "-w", "\n__HTTP_STATUS__%{http_code}",
    ];
    if (extraHeaders) {
        for (const [key, value] of Object.entries(extraHeaders)) {
            args.push("-H", `${key}: ${value}`);
        }
    }
    if (body && (method === "POST" || method === "PUT" || method === "PATCH")) {
        args.push("-d", body);
    }
    args.push(url);
    const result = exec("curl", args, { timeout: timeout ?? 30_000 });
    const output = result.stdout;
    const statusMatch = output.match(/__HTTP_STATUS__(\d+)$/);
    const httpStatus = statusMatch ? parseInt(statusMatch[1], 10) : 0;
    const raw = output.replace(/__HTTP_STATUS__\d+$/, "").trim();
    if (!result.ok && httpStatus === 0) {
        return {
            ok: false,
            status: 0,
            data: null,
            raw: "",
            error: result.stderr || "curl failed",
        };
    }
    let data = raw;
    try {
        data = JSON.parse(raw);
    }
    catch {
        // keep as string
    }
    return {
        ok: httpStatus >= 200 && httpStatus < 400,
        status: httpStatus,
        data,
        raw,
        error: httpStatus >= 400 ? `HTTP ${httpStatus}` : undefined,
    };
}
function getBearerToken() {
    try {
        const tokens = JSON.parse(readFileSync(AUTHELIA_TOKEN_PATH, "utf-8"));
        return tokens.access_token || null;
    }
    catch {
        return null;
    }
}
export function rustApiGet(endpoint, timeout) {
    // Try WireGuard mesh first
    const meshResult = httpRequest("GET", `${RUST_API_MESH}${endpoint}`, undefined, timeout);
    if (meshResult.ok || meshResult.status !== 0) {
        return meshResult;
    }
    // Mesh failed (status 0 = connection failed), try public with bearer token
    const token = getBearerToken();
    if (token) {
        return httpRequest("GET", `${RUST_API_PUBLIC}${endpoint}`, undefined, timeout, { Authorization: `Bearer ${token}` });
    }
    // No token available, return mesh failure
    return meshResult;
}
export function rustApiPost(endpoint, body, timeout) {
    // Try WireGuard mesh first
    const meshResult = httpRequest("POST", `${RUST_API_MESH}${endpoint}`, body, timeout);
    if (meshResult.ok || meshResult.status !== 0) {
        return meshResult;
    }
    // Mesh failed, try public with bearer token
    const token = getBearerToken();
    if (token) {
        return httpRequest("POST", `${RUST_API_PUBLIC}${endpoint}`, body, timeout, { Authorization: `Bearer ${token}` });
    }
    return meshResult;
}
export function httpGet(url, timeout) {
    return httpRequest("GET", url, undefined, timeout);
}
export function rawHttpRequest(method, url, body, timeout, extraHeaders) {
    return httpRequest(method, url, body, timeout, extraHeaders);
}
//# sourceMappingURL=http.js.map