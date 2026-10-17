export const api: typeof chrome = (globalThis as typeof globalThis & { browser?: typeof chrome }).browser ?? chrome;
export const isFirefox = typeof (api.runtime as typeof api.runtime & { getBrowserInfo?: unknown }).getBrowserInfo === 'function';
