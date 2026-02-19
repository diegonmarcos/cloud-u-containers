export interface HttpResult {
    ok: boolean;
    status: number;
    data: unknown;
    raw: string;
    error?: string;
}
export declare function rustApiGet(endpoint: string, timeout?: number): HttpResult;
export declare function rustApiPost(endpoint: string, body?: string, timeout?: number): HttpResult;
export declare function httpGet(url: string, timeout?: number): HttpResult;
export declare function rawHttpRequest(method: string, url: string, body?: string, timeout?: number, extraHeaders?: Record<string, string>): HttpResult;
