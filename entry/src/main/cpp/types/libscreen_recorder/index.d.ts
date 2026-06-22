export interface CreateRecorderOptions {
  outputPath: string;
  width: number;
  height: number;
  frameRate: number;
  videoBitrate: number;
  preset: string;
}

export interface CreateRecorderResult {
  recorderId: number;
  surfaceId: string;
}

export interface StopRecorderResult {
  outputPath: string;
  durationMs: number;
  frameCount: number;
  avgFrameIntervalMs: number;
  isScaffold: boolean;
}

export function getVersion(): string;
export function createRecorder(options: CreateRecorderOptions): Promise<CreateRecorderResult>;
export function startRecorder(recorderId: number): Promise<void>;
export function stopRecorder(recorderId: number): Promise<StopRecorderResult>;
export function releaseRecorder(recorderId: number): void;
