// ── Mattermost tools — chat read/write for the agentic bot (8 tools) ──

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { mmApi, getBotUserId, resolveChannel, searchUsers, isMmConfigured, MM_TEAM_ID } from "../../shared/mattermost.js";

interface Post {
  id: string;
  user_id: string;
  channel_id: string;
  message: string;
  create_at: number;
  root_id: string;
}

interface PostsResponse {
  order: string[];
  posts: Record<string, Post>;
}

interface Channel {
  id: string;
  type: string;
  name: string;
  display_name: string;
}

export function registerMattermostTools(server: McpServer): void {
  // ── mm_read ──────────────────────────────────────────────────
  server.tool(
    "mm-read",
    "Read recent messages from a Mattermost channel",
    {
      channel: z.string().optional().describe("Channel name or ID (default: DM with diego)"),
      limit: z.number().min(1).max(100).default(10).describe("Number of messages to fetch"),
    },
    async ({ channel, limit }) => {
      if (!isMmConfigured()) return { content: [{ type: "text" as const, text: "MM_BOT_TOKEN not configured" }] };

      const chId = await resolveChannel(channel);
      const data = (await mmApi("GET", `/api/v4/channels/${chId}/posts?per_page=${limit}`)) as PostsResponse;

      const allPosts = Object.values(data.posts).sort((a, b) => a.create_at - b.create_at);
      const userIds = [...new Set(allPosts.map((p) => p.user_id))];
      const userMap = new Map<string, string>();
      for (const uid of userIds) {
        const u = (await mmApi("GET", `/api/v4/users/${uid}`)) as { username: string };
        userMap.set(uid, u.username);
      }

      const lines = allPosts.map((p) => {
        const time = new Date(p.create_at).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
        const user = userMap.get(p.user_id) || "unknown";
        const thread = p.root_id ? " [thread]" : "";
        return `[${time}] @${user}${thread}: ${p.message}`;
      });

      return { content: [{ type: "text" as const, text: lines.join("\n") || "(no messages)" }] };
    }
  );

  // ── mm_post ──────────────────────────────────────────────────
  server.tool(
    "mm-post",
    "Post a message to a Mattermost channel",
    {
      message: z.string().describe("Message text (Markdown supported)"),
      channel: z.string().optional().describe("Channel name or ID (default: DM with diego)"),
    },
    async ({ message, channel }) => {
      if (!isMmConfigured()) return { content: [{ type: "text" as const, text: "MM_BOT_TOKEN not configured" }] };

      const chId = await resolveChannel(channel);
      const post = (await mmApi("POST", "/api/v4/posts", {
        channel_id: chId,
        message,
      })) as { id: string };

      return { content: [{ type: "text" as const, text: `Posted to channel ${chId} (id: ${post.id})` }] };
    }
  );

  // ── mm_reply ─────────────────────────────────────────────────
  server.tool(
    "mm-reply",
    "Reply to a message in a thread",
    {
      post_id: z.string().describe("ID of the post to reply to"),
      message: z.string().describe("Reply message text"),
    },
    async ({ post_id, message }) => {
      if (!isMmConfigured()) return { content: [{ type: "text" as const, text: "MM_BOT_TOKEN not configured" }] };

      const original = (await mmApi("GET", `/api/v4/posts/${post_id}`)) as Post;
      const rootId = original.root_id || post_id;
      const reply = (await mmApi("POST", "/api/v4/posts", {
        channel_id: original.channel_id,
        message,
        root_id: rootId,
      })) as { id: string };

      return { content: [{ type: "text" as const, text: `Replied in thread ${rootId} (reply id: ${reply.id})` }] };
    }
  );

  // ── mm_channels ──────────────────────────────────────────────
  server.tool(
    "mm-channels",
    "List Mattermost channels the bot has access to",
    {},
    async () => {
      if (!isMmConfigured()) return { content: [{ type: "text" as const, text: "MM_BOT_TOKEN not configured" }] };

      const uid = await getBotUserId();
      const channels = (await mmApi("GET", `/api/v4/users/${uid}/teams/${MM_TEAM_ID}/channels`)) as Channel[];

      const typeLabel: Record<string, string> = { O: "Public", P: "Private", D: "DM", G: "Group" };
      const lines = [
        "Type    | Name                 | Display Name",
        "--------|----------------------|-------------",
      ];
      for (const ch of channels) {
        const t = (typeLabel[ch.type] || ch.type).padEnd(7);
        const n = ch.name.substring(0, 20).padEnd(20);
        lines.push(`${t} | ${n} | ${ch.display_name || "-"}`);
      }

      return { content: [{ type: "text" as const, text: lines.join("\n") }] };
    }
  );

  // ── mm_react ─────────────────────────────────────────────────
  server.tool(
    "mm-react",
    "Add an emoji reaction to a post",
    {
      post_id: z.string().describe("ID of the post to react to"),
      emoji_name: z.string().describe("Emoji name without colons (e.g. thumbsup, heart, rocket)"),
    },
    async ({ post_id, emoji_name }) => {
      if (!isMmConfigured()) return { content: [{ type: "text" as const, text: "MM_BOT_TOKEN not configured" }] };

      const uid = await getBotUserId();
      await mmApi("POST", "/api/v4/reactions", { user_id: uid, post_id, emoji_name });

      return { content: [{ type: "text" as const, text: `Reacted with :${emoji_name}: on post ${post_id}` }] };
    }
  );

  // ── mm_user_search ───────────────────────────────────────────
  server.tool(
    "mm-user_search",
    "Search for Mattermost users by username or email",
    {
      term: z.string().describe("Username or email to search for"),
    },
    async ({ term }) => {
      if (!isMmConfigured()) return { content: [{ type: "text" as const, text: "MM_BOT_TOKEN not configured" }] };

      const users = await searchUsers(term);
      if (!users.length) return { content: [{ type: "text" as const, text: `No users found for "${term}"` }] };

      const lines = [
        "ID                         | Username             | Email",
        "---------------------------|----------------------|------",
      ];
      for (const u of users) {
        lines.push(`${u.id} | ${u.username.padEnd(20)} | ${u.email || "-"}`);
      }
      return { content: [{ type: "text" as const, text: lines.join("\n") }] };
    }
  );

  // ── mm_create_group_dm ───────────────────────────────────────
  server.tool(
    "mm-create_group_dm",
    "Create a group DM channel with multiple users (by user IDs)",
    {
      user_ids: z.array(z.string()).describe("Array of Mattermost user IDs to include (bot's own ID added automatically)"),
    },
    async ({ user_ids }) => {
      if (!isMmConfigured()) return { content: [{ type: "text" as const, text: "MM_BOT_TOKEN not configured" }] };

      const uid = await getBotUserId();
      if (!user_ids.includes(uid)) user_ids.push(uid);
      const ch = (await mmApi("POST", "/api/v4/channels/group", user_ids)) as { id: string };

      return { content: [{ type: "text" as const, text: `Group DM created (channel id: ${ch.id})` }] };
    }
  );

  // ── mm_add_to_channel ────────────────────────────────────────
  server.tool(
    "mm-add_to_channel",
    "Add a user to a channel (public/private/group — does not work on DMs)",
    {
      channel: z.string().describe("Channel name or ID"),
      user_id: z.string().describe("User ID to add"),
    },
    async ({ channel, user_id }) => {
      if (!isMmConfigured()) return { content: [{ type: "text" as const, text: "MM_BOT_TOKEN not configured" }] };

      const chId = await resolveChannel(channel);
      const member = (await mmApi("POST", `/api/v4/channels/${chId}/members`, { user_id })) as {
        channel_id: string;
        user_id: string;
      };

      return { content: [{ type: "text" as const, text: `Added user ${member.user_id} to channel ${member.channel_id}` }] };
    }
  );
}
