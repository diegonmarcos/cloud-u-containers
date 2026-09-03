import { useRef, useCallback } from 'react';

interface UseLongPressOptions {
  delay?: number;
  onLongPress: (e: React.TouchEvent) => void;
  moveThreshold?: number;
}

export function useLongPress({ delay = 300, onLongPress, moveThreshold = 10 }: UseLongPressOptions) {
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const startPos = useRef<{ x: number; y: number } | null>(null);
  const targetRef = useRef<HTMLElement | null>(null);
  const triggered = useRef(false);

  const clear = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    if (targetRef.current) {
      targetRef.current.style.transform = '';
      targetRef.current = null;
    }
    triggered.current = false;
  }, []);

  const onTouchStart = useCallback((e: React.TouchEvent) => {
    const touch = e.touches[0];
    startPos.current = { x: touch.clientX, y: touch.clientY };
    targetRef.current = e.currentTarget as HTMLElement;
    triggered.current = false;

    timerRef.current = setTimeout(() => {
      triggered.current = true;
      if (targetRef.current) {
        targetRef.current.style.transform = '';
      }
      if (navigator.vibrate) {
        navigator.vibrate(10);
      }
      onLongPress(e);
    }, delay);

    if (targetRef.current) {
      targetRef.current.style.transform = 'scale(0.98)';
    }
  }, [delay, onLongPress]);

  const onTouchMove = useCallback((e: React.TouchEvent) => {
    if (!startPos.current) return;
    const touch = e.touches[0];
    const dx = Math.abs(touch.clientX - startPos.current.x);
    const dy = Math.abs(touch.clientY - startPos.current.y);
    if (dx > moveThreshold || dy > moveThreshold) {
      clear();
    }
  }, [moveThreshold, clear]);

  const onTouchEnd = useCallback((e: React.TouchEvent) => {
    if (triggered.current) {
      e.preventDefault();
    }
    clear();
  }, [clear]);

  return { onTouchStart, onTouchMove, onTouchEnd };
}
