import nodemailer from "nodemailer";

export function getTransport(): nodemailer.Transporter {
  return nodemailer.createTransport({
    host: process.env.MAIL_HOST ?? "smtp.diegonmarcos.com",
    port: 465,
    secure: true,
    auth: {
      user: process.env.MAIL_USER!,
      pass: process.env.MAIL_PASSWORD!,
    },
  });
}
