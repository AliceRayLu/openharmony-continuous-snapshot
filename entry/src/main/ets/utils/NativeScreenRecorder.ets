import nativeRecorderModule from 'libentry.so';

export interface NativeCreateRecorderOptions {
  outputPath: string;
  width: number;
  height: number;
  frameRate: number;
  videoBitrate: number;
  preset: string;
  micEnabled: boolean;
}

export interface NativeCreateRecorderResult {
  recorderId: number;
}

export interface NativeStopRecorderResult {
  outputPath: string;
  durationMs: number;
  hasVideo: boolean;
  frameWidth: number;
  frameHeight: number;
  errorMessage: string;
}

interface NativeRecorderModuleApi {
  getVersion?: () => string;
  createRecorder?: (options: NativeCreateRecorderOptions) => Promise<NativeCreateRecorderResult>;
  startRecorder?: (recorderId: number) => Promise<void>;
  stopRecorder?: (recorderId: number) => Promise<NativeStopRecorderResult>;
  releaseRecorder?: (recorderId: number) => void;
}

class NativeScreenRecorderModule {
  private getBridge(): NativeRecorderModuleApi {
    const bridge = nativeRecorderModule as NativeRecorderModuleApi | undefined;
    if (!bridge) {
      throw new Error('Native recorder module default export resolved to undefined');
    }
    return bridge;
  }

  private getBridgeKeys(bridge: NativeRecorderModuleApi): string {
    try {
      const keys = Object.keys(bridge as Object);
      return keys.length > 0 ? keys.join(',') : '(empty)';
    } catch (_err) {
      return '(unavailable)';
    }
  }

  private ensureFunction<T>(fn: T | undefined, name: string, bridge: NativeRecorderModuleApi): T {
    if (!fn) {
      throw new Error(`Native recorder module does not expose ${name}() on default export, keys=[${this.getBridgeKeys(bridge)}]`);
    }
    return fn;
  }

  async getVersion(): Promise<string> {
    const bridge = this.getBridge();
    const getVersion = this.ensureFunction(bridge.getVersion, 'getVersion', bridge);
    return getVersion();
  }

  async createRecorder(options: NativeCreateRecorderOptions): Promise<NativeCreateRecorderResult> {
    const bridge = this.getBridge();
    const createRecorder = this.ensureFunction(bridge.createRecorder, 'createRecorder', bridge);
    return createRecorder(options);
  }

  async startRecorder(recorderId: number): Promise<void> {
    const bridge = this.getBridge();
    const startRecorder = this.ensureFunction(bridge.startRecorder, 'startRecorder', bridge);
    await startRecorder(recorderId);
  }

  async stopRecorder(recorderId: number): Promise<NativeStopRecorderResult> {
    const bridge = this.getBridge();
    const stopRecorder = this.ensureFunction(bridge.stopRecorder, 'stopRecorder', bridge);
    return stopRecorder(recorderId);
  }

  releaseRecorder(recorderId: number): void {
    const bridge = this.getBridge();
    const releaseRecorder = this.ensureFunction(bridge.releaseRecorder, 'releaseRecorder', bridge);
    releaseRecorder(recorderId);
  }
}

export const NativeScreenRecorder = new NativeScreenRecorderModule();
