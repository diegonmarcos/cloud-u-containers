import { describe, expect, it } from 'vitest';

import { getFilePreviewKind, isFilePreviewable } from '../file-preview';

describe('file preview detection', () => {
  it('detects browser-renderable image attachments', () => {
    expect(getFilePreviewKind('photo.avif', 'image/avif')).toBe('image');
    expect(getFilePreviewKind('vector.svg')).toBe('image');
  });

  it('detects html attachments', () => {
    expect(getFilePreviewKind('message.html', 'text/html; charset=utf-8')).toBe('html');
    expect(getFilePreviewKind('index.htm')).toBe('html');
  });

  it('detects text and markdown attachments', () => {
    expect(getFilePreviewKind('notes.txt', 'text/plain')).toBe('text');
    expect(getFilePreviewKind('README.md', 'text/markdown')).toBe('markdown');
    expect(getFilePreviewKind('payload.json', 'application/json')).toBe('text');
  });

  it('detects pdf, audio, and video attachments', () => {
    expect(getFilePreviewKind('doc.pdf')).toBe('pdf');
    expect(getFilePreviewKind('audio.m4a')).toBe('audio');
    expect(getFilePreviewKind('movie.webm')).toBe('video');
  });

  it('rejects unsupported attachment types', () => {
    expect(getFilePreviewKind('archive.zip', 'application/zip')).toBe('unsupported');
    expect(isFilePreviewable('archive.zip', 'application/zip')).toBe(false);
  });
});