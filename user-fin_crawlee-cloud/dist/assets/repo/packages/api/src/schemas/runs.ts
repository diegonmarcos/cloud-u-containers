import { z } from 'zod';

export const UpdateRunSchema = z.object({
  status: z.enum(['READY', 'RUNNING', 'SUCCEEDED', 'FAILED', 'TIMED-OUT', 'ABORTED']).optional(),
  statusMessage: z.string().max(1000).optional(),
});
