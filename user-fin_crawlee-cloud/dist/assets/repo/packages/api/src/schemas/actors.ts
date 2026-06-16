import { z } from 'zod';

export const CreateActorSchema = z.object({
  name: z
    .string()
    .min(1)
    .max(100)
    .regex(
      /^[a-zA-Z0-9._-]+$/,
      'Name must contain only letters, numbers, dots, dashes, and underscores'
    ),
  title: z.string().max(200).optional(),
  description: z.string().max(5000).optional(),
  defaultRunOptions: z
    .object({
      build: z.string().optional(),
      timeoutSecs: z.number().int().positive().optional(),
      memoryMbytes: z.number().int().positive().optional(),
    })
    .optional(),
  maxRetries: z.number().int().min(0).max(10).optional(),
  retryDelaySecs: z.number().int().min(1).max(3600).optional(),
});

export const UpdateActorSchema = CreateActorSchema.partial();

export const ActorRunSchema = z.object({
  input: z.unknown().optional(),
  timeout: z.number().int().positive().max(86400).optional(), // Max 24h
  memory: z.number().int().positive().max(16384).optional(), // Max 16GB
  envVars: z.record(z.string()).optional(),
});
