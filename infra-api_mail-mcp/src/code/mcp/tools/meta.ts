import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  handle_mail_list_folders,
  handle_mail_list_messages,
  handle_mail_read,
  handle_mail_search,
  handle_mail_flag,
  handle_mail_move,
  handle_mail_delete,
  handle_mail_download_attachment,
  handle_mail_create_folder,
  handle_mail_delete_folder,
} from "./inbox.js";
import {
  handle_mail_send,
  handle_mail_reply,
  handle_mail_forward,
} from "./compose.js";
import {
  handle_mail_admin_users,
  handle_mail_admin_domains,
} from "./admin.js";
import {
  handle_resend_send,
  handle_resend_get,
  handle_resend_list,
  handle_resend_domains,
  handle_resend_domain_verify,
  handle_resend_domain_dns,
  handle_resend_api_keys,
} from "./resend.js";
import {
  handle_debug_outbound,
  handle_debug_inbound,
  handle_debug_trace,
} from "./debug.js";
import {
  handle_stalwart_admin_accounts,
  handle_stalwart_admin_domains,
  handle_stalwart_admin_settings,
} from "./stalwart.js";

const DISPATCH: Record<string, (params: any) => Promise<any>> = {
  mail_list_folders: handle_mail_list_folders,
  mail_list_messages: handle_mail_list_messages,
  mail_read: handle_mail_read,
  mail_search: handle_mail_search,
  mail_flag: handle_mail_flag,
  mail_move: handle_mail_move,
  mail_delete: handle_mail_delete,
  mail_download_attachment: handle_mail_download_attachment,
  mail_create_folder: handle_mail_create_folder,
  mail_delete_folder: handle_mail_delete_folder,
  mail_send: handle_mail_send,
  mail_reply: handle_mail_reply,
  mail_forward: handle_mail_forward,
  mail_admin_users: handle_mail_admin_users,
  mail_admin_domains: handle_mail_admin_domains,
  resend_send: handle_resend_send,
  resend_get: handle_resend_get,
  resend_list: handle_resend_list,
  resend_domains: handle_resend_domains,
  resend_domain_verify: handle_resend_domain_verify,
  resend_domain_dns: handle_resend_domain_dns,
  resend_api_keys: handle_resend_api_keys,
  debug_outbound: handle_debug_outbound,
  debug_inbound: handle_debug_inbound,
  debug_trace: handle_debug_trace,
  stalwart_admin_accounts: handle_stalwart_admin_accounts,
  stalwart_admin_domains: handle_stalwart_admin_domains,
  stalwart_admin_settings: handle_stalwart_admin_settings,
};

export function registerMetaTool(server: McpServer): void {
  server.tool(
    "mail",
    "Unified mail tool — set method to one of: debug_inbound, debug_outbound, debug_trace, mail_admin_domains, mail_admin_users, mail_create_folder, mail_delete, mail_delete_folder, mail_download_attachment, mail_flag, mail_forward, mail_list_folders, mail_list_messages, mail_move, mail_read, mail_reply, mail_search, mail_send, resend_api_keys, resend_domain_dns, resend_domains, resend_domain_verify, resend_get, resend_list, resend_send, stalwart_admin_accounts, stalwart_admin_domains, stalwart_admin_settings",
    {
      method: z.enum([
        "debug_inbound",
        "debug_outbound",
        "debug_trace",
        "mail_admin_domains",
        "mail_admin_users",
        "mail_create_folder",
        "mail_delete",
        "mail_delete_folder",
        "mail_download_attachment",
        "mail_flag",
        "mail_forward",
        "mail_list_folders",
        "mail_list_messages",
        "mail_move",
        "mail_read",
        "mail_reply",
        "mail_search",
        "mail_send",
        "resend_api_keys",
        "resend_domain_dns",
        "resend_domains",
        "resend_domain_verify",
        "resend_get",
        "resend_list",
        "resend_send",
        "stalwart_admin_accounts",
        "stalwart_admin_domains",
        "stalwart_admin_settings",
      ]),
      params: z.record(z.unknown()).optional(),
    },
    async ({ method, params }) => {
      const handler = DISPATCH[method];
      if (!handler) throw new Error(`Unknown method: ${method}`);
      return handler((params ?? {}) as any);
    }
  );
}
