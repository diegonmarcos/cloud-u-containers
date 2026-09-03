'use client';

import React from 'react';
import type { SlotRegistration } from '@/lib/plugin-types';
import { PluginErrorBoundary } from './plugin-error-boundary';

interface PluginSlotRendererProps {
  registration: SlotRegistration;
  fallback?: React.ReactNode;
  extraProps?: Record<string, unknown>;
}

export function PluginSlotRenderer({ registration, fallback = null, extraProps }: PluginSlotRendererProps) {
  const Component = registration.component;

  return (
    <PluginErrorBoundary pluginId={registration.pluginId} fallback={fallback}>
      <Component {...(extraProps ?? {})} />
    </PluginErrorBoundary>
  );
}
