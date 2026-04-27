import { createHash } from 'node:crypto';
import { SystemConfig } from 'src/config';

export type VideoFaceDetectionConfig = SystemConfig['machineLearning']['facialRecognition']['video'];

export const getVideoFaceFrameConfigHash = ({
  intervalSeconds,
  maxFramesPerVideo,
  downscaleLongEdge,
}: VideoFaceDetectionConfig): string =>
  createHash('sha1').update(`${intervalSeconds}:${maxFramesPerVideo}:${downscaleLongEdge}`).digest('hex').slice(0, 10);

export const selectVideoFaceFrameTimestamps = (
  durationSeconds: number,
  { intervalSeconds, maxFramesPerVideo }: VideoFaceDetectionConfig,
): number[] => {
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    return [];
  }

  if (durationSeconds <= intervalSeconds) {
    return [durationSeconds / 2];
  }

  const intervalFrameCount = Math.ceil(durationSeconds / intervalSeconds);
  const frameCount = Math.min(intervalFrameCount, maxFramesPerVideo);
  if (intervalFrameCount > maxFramesPerVideo) {
    const distributedInterval = durationSeconds / frameCount;
    return Array.from({ length: frameCount }, (_, index) => {
      const start = index * distributedInterval;
      const end = Math.min(durationSeconds, start + distributedInterval);
      return (start + end) / 2;
    });
  }

  return Array.from({ length: frameCount }, (_, index) => {
    const start = index * intervalSeconds;
    const end = Math.min(durationSeconds, start + intervalSeconds);
    return (start + end) / 2;
  });
};
