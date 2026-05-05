import { z } from 'zod';

export const CreateWebhookSchema = z.object({
  eventTypes: z.array(z.string().min(1)).min(1),
  requestUrl: z.string().url(),
  payloadTemplate: z.string().max(10000).optional(),
  actorId: z.string().max(21).optional(),
  headers: z.record(z.string()).optional(),
  description: z.string().max(1000).optional(),
  isEnabled: z.boolean().optional(),
});

export const UpdateWebhookSchema = CreateWebhookSchema.partial();
