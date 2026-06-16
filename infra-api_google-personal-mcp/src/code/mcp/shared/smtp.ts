import nodemailer from "nodemailer";
import { resolveAccount } from "./config.js";

export function getTransport(alias?: string): { transport: nodemailer.Transporter; from: string } {
  const acc = resolveAccount(alias);
  const transport = nodemailer.createTransport({
    host: acc.smtpHost,
    port: acc.smtpPort,
    secure: true,
    auth: { user: acc.email, pass: acc.password },
  });
  return { transport, from: acc.email };
}
