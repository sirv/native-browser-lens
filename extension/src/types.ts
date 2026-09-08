export interface OwnerRule { pattern: string; memberId: string; label: string }
export interface ProjectProfile { id: string; name: string; origins: string[]; repositoryPath: string; documentationPaths: string[]; recording: 'diagnostics' | 'video'; enabled: boolean; adapter: 'generic' | 'sirv' | 'sirv-studio'; ownership: OwnerRule[]; logPaths: string[] }
export type CaptureMode = 'deep' | 'devtools' | 'handover' | 'paused' | 'unavailable';
export interface TabStatus { tabId: number; windowId: number; projectId: string; url: string; title: string; mode: CaptureMode; documentId: string; armedAt: number; capabilities: string[]; reason?: string; active: boolean }
export interface CaptureIdentity { projectId: string; tabId: number; windowId: number; documentId: string; url: string; title: string; capturedAt: number; buildId?: string }
export interface EvidenceEvent { id: string; projectId: string; tabId: number; documentId: string; timestamp: number; kind: string; data: Record<string, unknown> }
export interface CoverageGap { channel: string; reason: string; startedAt: number; endedAt?: number }
export interface CapturePayload { identity: CaptureIdentity; events: EvidenceEvent[]; gaps: CoverageGap[]; context?: Record<string, unknown> }
export interface WireMessage { version: 1; kind: string; id: string; payload: Record<string, unknown> }
export interface TabInput { id: number; windowId: number; url: string; title?: string; active: boolean }
