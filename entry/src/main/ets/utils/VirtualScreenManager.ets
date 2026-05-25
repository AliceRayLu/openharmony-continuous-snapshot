// VirtualScreenManager.ets
import screen from '@ohos.screen';
import screenshot from '@ohos.screenshot';
import display from '@ohos.display';
import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';

export interface ScreenshotOptions {
  intervalMs: number;      // 截图间隔（毫秒）
  durationSec: number;     // 总持续时间（秒）
  outputDir: string;       // 输出目录
  pixelThreshold?: number; // 帧差异阈值（默认0.95）
}

export interface FrameData {
  index: number;
  timestamp: number;       // 时间戳（纳秒）
  path: string;            // 文件保存路径
  hash: string;            // 图像哈希（用于快速比对）
  width: number;
  height: number;
}

export interface AnalysisResult {
  totalFrames: number;
  expectedFps: number;           // 理论帧率 = 1000 / intervalMs
  actualFps: number;             // 实际帧率
  frameDropRate: number;         // 丢帧率
  avgCaptureTimeMs: number;      // 平均截图耗时（毫秒）
  maxCaptureTimeMs: number;      // 最大截图耗时（毫秒）
  abnormalTimestamps: number[];  // 异常帧时间点
  status: 'NORMAL' | 'WARNING' | 'ABNORMAL';
  message: string;
}

export class VirtualScreenManager {
  private virtualScreenId: number = -1;
  private mirrorGroupId: number = -1;
  private mainScreenId: number = -1;
  private defaultDisplayId: number = -1;
  private isCapturing: boolean = false;
  private timerId: number = -1;
  private frameList: FrameData[] = [];
  private options: ScreenshotOptions;
  private captureStartTime: number = 0;
  private captureTimes: number[] = [];

  constructor(options: ScreenshotOptions) {
    this.options = options;
  }

  /**
   * 获取默认主屏 ID
   */
  private async getDefaultMainScreenId(): Promise<number> {
    try {
      const allScreens = await screen.getAllScreens();
      const mainScreen = allScreens.find(s => s.sourceMode === screen.ScreenSourceMode.SCREEN_MAIN);
      if (mainScreen) {
        return mainScreen.id;
      }
      if (allScreens.length > 0) {
        return allScreens[0].id;
      }
      throw new Error('No screen available');
    } catch (err) {
      let error = err as BusinessError;
      console.error(`[VirtualScreen] Get main screen failed: ${error.code} - ${error.message}`);
      throw new Error('Failed to get main screen');
    }
  }

  /**
   * 创建虚拟屏幕并设置镜像
   */
  async createVirtualScreen(width?: number, height?: number): Promise<number> {
    if (this.virtualScreenId !== -1) {
      console.warn('[VirtualScreen] Virtual screen already exists');
      return this.virtualScreenId;
    }

    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      this.defaultDisplayId = defaultDisplay.id;
      const screenWidth = width ?? defaultDisplay.width;
      const screenHeight = height ?? defaultDisplay.height;
      const density = defaultDisplay.densityDPI;
      console.info(`[VirtualScreen] Default display id=${defaultDisplay.id}, width=${defaultDisplay.width}, height=${defaultDisplay.height}, density=${defaultDisplay.densityDPI}`);

      const virtualScreenObj = await screen.createVirtualScreen({
        name: 'ContinuousScreenshotVirtualScreen',
        width: screenWidth,
        height: screenHeight,
        density: density,
        surfaceId: ''
      });

      this.virtualScreenId = virtualScreenObj.id;
      console.info(`[VirtualScreen] Virtual screen created, ID: ${this.virtualScreenId}, parent=${virtualScreenObj.parent}, sourceMode=${virtualScreenObj.sourceMode}`);

      const mainScreenId = await this.getDefaultMainScreenId();
      this.mainScreenId = mainScreenId;
      console.info(`[VirtualScreen] Preparing mirror, mainScreenId=${mainScreenId}, virtualScreenId=${this.virtualScreenId}, defaultDisplayId=${this.defaultDisplayId}`);
      this.mirrorGroupId = await screen.makeMirror(mainScreenId, [this.virtualScreenId]);
      console.info(`[VirtualScreen] Mirror set, group ID: ${this.mirrorGroupId}, mainScreenId=${mainScreenId}, virtualScreenId=${this.virtualScreenId}`);

      return this.virtualScreenId;
    } catch (err) {
      let error = err as BusinessError;
      console.error(`[VirtualScreen] Create/mirror failed: ${error.code} - ${error.message}`);
      throw new Error(`Failed to create virtual screen: ${error.message}`);
    }
  }

  /**
   * 销毁虚拟屏幕
   */
  async destroyVirtualScreen(): Promise<void> {
    if (this.virtualScreenId === -1) return;

    try {
      if (this.mirrorGroupId !== -1) {
        await screen.stopMirror([this.virtualScreenId]);
        console.info('[VirtualScreen] Mirror stopped');
        this.mirrorGroupId = -1;
      }
      await screen.destroyVirtualScreen(this.virtualScreenId);
      this.virtualScreenId = -1;
      console.info('[VirtualScreen] Virtual screen destroyed');
    } catch (err) {
      let error = err as BusinessError;
      console.error(`[VirtualScreen] Destroy failed: ${error.code} - ${error.message}`);
      throw new Error(`Failed to destroy virtual screen: ${error.message}`);
    }
  }

  /**
   * 开始连续截图
   */
  async startContinuousCapture(onProgress?: (progress: number) => void): Promise<FrameData[]> {
    if (this.isCapturing) {
      throw new Error('Capture already in progress');
    }
    if (this.virtualScreenId === -1) {
      throw new Error('Virtual screen not created, call createVirtualScreen first');
    }

    this.frameList = [];
    this.captureTimes = [];
    this.isCapturing = true;
    this.captureStartTime = Date.now();

    const totalFrames = Math.ceil((this.options.durationSec * 1000) / this.options.intervalMs);
    let frameIndex = 0;

    console.info(`[Capture] Starting continuous capture, target ${totalFrames} frames, intervalMs=${this.options.intervalMs}, durationSec=${this.options.durationSec}, outputDir=${this.options.outputDir}, virtualScreenId=${this.virtualScreenId}, mainScreenId=${this.mainScreenId}, defaultDisplayId=${this.defaultDisplayId}`);

    return new Promise((resolve, reject) => {
      this.timerId = setInterval(async () => {
        if (!this.isCapturing) {
          clearInterval(this.timerId);
          resolve(this.frameList);
          return;
        }

        const frameStart = Date.now();
        try {
          const frameData = await this.captureSingleFrame(frameIndex);
          frameData.index = frameIndex;
          this.frameList.push(frameData);
          this.captureTimes.push(Date.now() - frameStart);

          if (onProgress) {
            onProgress((frameIndex + 1) / totalFrames);
          }

          frameIndex++;

          const elapsed = (Date.now() - this.captureStartTime) / 1000;
          if (elapsed >= this.options.durationSec) {
            await this.stopContinuousCapture();
            resolve(this.frameList);
          }
        } catch (err) {
          console.error(`[Capture] Frame ${frameIndex} failed:`, err);
        }
      }, this.options.intervalMs);
    });
  }

  /**
   * 停止连续截图
   */
  async stopContinuousCapture(): Promise<void> {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.isCapturing = false;
    console.info(`[Capture] Stopped, captured ${this.frameList.length} frames`);
  }

  /**
   * 单帧截图 - 使用修正后的 screenshot API
   */
  private async captureSingleFrame(frameIndex: number): Promise<FrameData> {
    const timestamp = Date.now() * 1000000;
    const outputPath = `${this.options.outputDir}/frame_${timestamp}.jpg`;

    try {
      console.info(`[Capture] Frame ${frameIndex} request, displayId=${this.virtualScreenId}, virtualScreenId=${this.virtualScreenId}, mainScreenId=${this.mainScreenId}, defaultDisplayId=${this.defaultDisplayId}, outputPath=${outputPath}`);
      const pixelMap = await screenshot.save({
        displayId: this.virtualScreenId
      });
      console.info(`[Capture] Frame ${frameIndex} screenshot.save returned pixelMap`);

      await this.savePixelMapToFile(pixelMap, outputPath);
      console.info(`[Capture] Frame ${frameIndex} saved to ${outputPath}`);
      const hash = await this.computeImageHash(pixelMap);
      pixelMap.release();
      console.info(`[Capture] Frame ${frameIndex} released pixelMap`);

      return {
        index: frameIndex,
        timestamp: timestamp,
        path: outputPath,
        hash: hash,
        width: 0,
        height: 0
      };
    } catch (err) {
      let error = err as BusinessError;
      console.error(`[Capture] Frame ${frameIndex} screenshot failed, code=${error.code}, message=${error.message}, virtualScreenId=${this.virtualScreenId}, mainScreenId=${this.mainScreenId}, defaultDisplayId=${this.defaultDisplayId}`);
      throw new Error(`Screenshot failed: ${error.message}`);
    }
  }

  /**
   * 计算图像哈希（简化实现）
   */
  private async computeImageHash(pixelMap: image.PixelMap): Promise<string> {
    // 可根据需要实现感知哈希，此处返回简单标识
    return `${Date.now()}_${Math.random()}`;
  }

  /**
   * 保存 PixelMap 到文件
   */
  private async savePixelMapToFile(pixelMap: image.PixelMap, filePath: string): Promise<void> {
    try {
      const imagePackerApi = image.createImagePacker();
      const imageBuffer = await imagePackerApi.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: 85
      });

      if (imageBuffer) {
        const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
        fs.writeSync(file.fd, imageBuffer);
        fs.closeSync(file);
      }
      await imagePackerApi.release();
    } catch (err) {
      let error = err as BusinessError;
      console.error(`[Capture] Save file failed: ${error.message}`);
    }
  }

  /**
   * 分析截图帧率
   */
  async analyzeFrameRate(): Promise<AnalysisResult> {
    const totalFrames = this.frameList.length;
    const expectedIntervalMs = this.options.intervalMs;
    const expectedFps = Math.round(1000 / expectedIntervalMs);

    let totalCaptureTime = 0;
    let maxCaptureTime = 0;
    let abnormalCount = 0;
    let abnormalTimestamps: number[] = [];

    for (let i = 0; i < this.captureTimes.length; i++) {
      const captureTime = this.captureTimes[i];
      totalCaptureTime += captureTime;
      if (captureTime > maxCaptureTime) maxCaptureTime = captureTime;

      if (captureTime > expectedIntervalMs * 0.8) {
        abnormalCount++;
        if (this.frameList[i]) {
          abnormalTimestamps.push(this.frameList[i].timestamp);
        }
      }
    }

    const avgCaptureTime = totalCaptureTime / (this.captureTimes.length || 1);
    const totalTimeSec = (Date.now() - this.captureStartTime) / 1000;
    const actualFps = totalFrames / totalTimeSec;
    const frameDropRate = Math.abs(actualFps - expectedFps) / expectedFps;

    let status: 'NORMAL' | 'WARNING' | 'ABNORMAL' = 'NORMAL';
    let message = '';

    if (frameDropRate > 0.2 || abnormalCount > totalFrames * 0.1) {
      status = 'ABNORMAL';
      message = `Significant frame drop detected: expected ${expectedFps}fps, actual ${actualFps.toFixed(1)}fps`;
    } else if (frameDropRate > 0.05 || abnormalCount > totalFrames * 0.03) {
      status = 'WARNING';
      message = `Mild frame fluctuation detected: ${(frameDropRate * 100).toFixed(1)}% drop rate`;
    } else {
      message = 'Frame rate normal, no significant impact detected';
    }

    return {
      totalFrames: totalFrames,
      expectedFps: expectedFps,
      actualFps: actualFps,
      frameDropRate: frameDropRate,
      avgCaptureTimeMs: avgCaptureTime,
      maxCaptureTimeMs: maxCaptureTime,
      abnormalTimestamps: abnormalTimestamps,
      status: status,
      message: message
    };
  }

  getFrameData(): FrameData[] {
    return this.frameList;
  }

  async cleanup(): Promise<void> {
    await this.stopContinuousCapture();
    await this.destroyVirtualScreen();
  }
}