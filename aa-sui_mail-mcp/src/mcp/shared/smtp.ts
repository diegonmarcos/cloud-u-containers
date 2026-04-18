import nodemailer from "nodemailer";
import { getServer, getAccount } from "./config.js";

export function getTransport(server: string, account: string): nodemailer.Transporter {
  const srv = getServer(server);
  const creds = getAccount(server, account);

  return nodemailer.createTransport({
    host: srv.host,
    port: srv.smtp,
    secure: true,
    auth: { user: creds.user, pass: creds.password },
  });
}
