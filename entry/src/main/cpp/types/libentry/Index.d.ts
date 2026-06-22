export interface CreateRecorderOptions {
  outputPath: string;
  width: number;
  height: number;
  frameRate: number;
  videoBitrate: number;
  preset: string;
  micEnabled: boolean;
}

export interface CreateRecorderResult {
  recorderId: number;
}

export interface StopRecorderResult {
  outputPath: string;
  durationMs: number;
  hasVideo: boolean;
  frameWidth: number;
  frameHeight: number;
  errorMessage: string;
}

export function getVersion(): string;
export function createRecorder(options: CreateRecorderOptions): Promise<CreateRecorderResult>;
export function startRecorder(recorderId: number): Promise<void>;
export function stopRecorder(recorderId: number): Promise<StopRecorderResult>;
export function releaseRecorder(recorderId: number): void;
