import { z } from 'zod';

const cronRegex = /^(\S+\s+){4}\S+$/;

export const CreateScheduleSchema = z.object({
  actorId: z.string().min(1).max(21),
  name: z.string().min(1).max(200),
  cronExpression: z.string().regex(cronRegex, 'Must be a valid 5-field cron expression'),
  timezone: z.string().max(50).optional(),
  isEnabled: z.boolean().optional(),
  input: z.unknown().optional(),
});

export const UpdateScheduleSchema = CreateScheduleSchema.partial();
