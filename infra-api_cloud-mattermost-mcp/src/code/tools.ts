import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { api, ensureAuth, resolveChannel, getUsername, searchUsers, createGroupDm, MM_TEAM_ID } from "./client.js";

// Re-export userId as a getter since it's set after login
let getUserId = async (): Promise<string> => {
  await ensureAuth();
  // After ensureAuth, the module-level userId in client.ts is set,
  // but we can't import a let binding reactively. Use /users/me instead.
  const me = (await api("GET", "/api/v4/users/me")) as { id: string };
  return me.id;
};

interface Post {
  id: string;
  user_id: string;
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

export function registerTools(server: McpServer): void {
  // ── mm_read ──────────────────────────────────────────────────
  server.tool(
    "mm_read",
    "Read recent messages from a Mattermost channel",
    {
      channel: z.string().optional().describe("Channel name or ID (default: DM with diego)"),
      limit: z.number().min(1).max(100).default(10).describe("Number of messages to fetch"),
    },
    async ({ channel, limit }) => {
      const chId = await resolveChannel(channel);
      const data = (await api("GET", `/api/v4/channels/${chId}/posts?per_page=${limit}`)) as PostsResponse;
      const { order, posts } = data;

      // All posts sorted chronologically (order[] only has root posts, misses thread replies)
      const allPosts = Object.values(posts).sort((a, b) => a.create_at - b.create_at);

      // Collect unique user IDs for display names
      const userIds = [...new Set(allPosts.map((p) => p.user_id))];
      const userMap = new Map<string, string>();
      for (const uid of userIds) {
        const u = (await api("GET", `/api/v4/users/${uid}`)) as { username: string };
        userMap.set(uid, u.username);
      }

      const lines = allPosts.map((p) => {
        const time = new Date(p.create_at).toLocaleTimeString("en-GB", {
          hour: "2-digit",
          minute: "2-digit",
        });
        const user = userMap.get(p.user_id) || "unknown";
        const thread = p.root_id ? " [thread]" : "";
        return `[${time}] @${user}${thread}: ${p.message}`;
      });

      return { content: [{ type: "text", text: lines.join("\n") || "(no messages)" }] };
    }
  );

  // ── mm_post ──────────────────────────────────────────────────
  server.tool(
    "mm_post",
    "Post a message to a Mattermost channel",
    {
      message: z.string().describe("Message text (Markdown supported)"),
      channel: z.string().optional().describe("Channel name or ID (default: DM with diego)"),
    },
    async ({ message, channel }) => {
      const chId = await resolveChannel(channel);
      const post = (await api("POST", "/api/v4/posts", {
        channel_id: chId,
        message,
      })) as { id: string; channel_id: string };

      const username = getUsername();
      return {
        content: [{ type: "text", text: `Posted to channel ${chId} as @${username} (id: ${post.id})` }],
      };
    }
  );

  // ── mm_reply ─────────────────────────────────────────────────
  server.tool(
    "mm_reply",
    "Reply to a message in a thread",
    {
      post_id: z.string().describe("ID of the post to reply to"),
      message: z.string().describe("Reply message text"),
    },
    async ({ post_id, message }) => {
      // Get the original post to find channel_id and root_id
      const original = (await api("GET", `/api/v4/posts/${post_id}`)) as Post;
      const rootId = original.root_id || post_id; // If replying to a root post, use its ID

      const reply = (await api("POST", "/api/v4/posts", {
        channel_id: original.channel_id,
        message,
        root_id: rootId,
      })) as { id: string };

      return {
        content: [{ type: "text", text: `Replied in thread ${rootId} (reply id: ${reply.id})` }],
      };
    }
  );

  // ── mm_channels ──────────────────────────────────────────────
  server.tool(
    "mm_channels",
    "List Mattermost channels the bot has access to",
    {},
    async () => {
      const uid = await getUserId();
      const channels = (await api(
        "GET",
        `/api/v4/users/${uid}/teams/${MM_TEAM_ID}/channels`
      )) as Channel[];

      const typeLabel: Record<string, string> = {
        O: "Public",
        P: "Private",
        D: "DM",
        G: "Group",
      };

      const lines = [
        "Type    | Name                 | Display Name",
        "--------|----------------------|-------------",
      ];
      for (const ch of channels) {
        const t = (typeLabel[ch.type] || ch.type).padEnd(7);
        const n = ch.name.substring(0, 20).padEnd(20);
        lines.push(`${t} | ${n} | ${ch.display_name || "-"}`);
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  // ── mm_channels_grouped ────────────────────────────────────────
  server.tool(
    "mm_channels_grouped",
    "List Mattermost channels grouped by category prefix (vcs_, infra_, ops_, etc.)",
    {},
    async () => {
      const uid = await getUserId();
      const channels = (await api(
        "GET",
        `/api/v4/users/${uid}/teams/${MM_TEAM_ID}/channels`
      )) as Channel[];

      const groups: Record<string, string[]> = {};
      for (const ch of channels) {
        if (ch.type === "D" || ch.type === "G") continue;
        const cat = ch.name.includes("_") ? ch.name.split("_")[0] : "general";
        if (!groups[cat]) groups[cat] = [];
        groups[cat].push(ch.display_name || ch.name);
      }

      const lines: string[] = [];
      for (const [cat, chs] of Object.entries(groups).sort(([a], [b]) => a.localeCompare(b))) {
        lines.push(`## ${cat} (${chs.length})`);
        for (const name of chs.sort()) lines.push(`  - ${name}`);
        lines.push("");
      }

      const total = Object.values(groups).reduce((s, g) => s + g.length, 0);
      lines.push(`Total: ${total} channels, ${Object.keys(groups).length} groups`);

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  // ── mm_react ─────────────────────────────────────────────────
  server.tool(
    "mm_react",
    "Add an emoji reaction to a post",
    {
      post_id: z.string().describe("ID of the post to react to"),
      emoji_name: z.string().describe("Emoji name without colons (e.g. thumbsup, heart, rocket)"),
    },
    async ({ post_id, emoji_name }) => {
      const uid = await getUserId();
      await api("POST", "/api/v4/reactions", {
        user_id: uid,
        post_id,
        emoji_name,
      });

      return {
        content: [{ type: "text", text: `Reacted with :${emoji_name}: on post ${post_id}` }],
      };
    }
  );

  // ── mm_user_search ───────────────────────────────────────────
  server.tool(
    "mm_user_search",
    "Search for Mattermost users by username or email",
    {
      term: z.string().describe("Username or email to search for"),
    },
    async ({ term }) => {
      const users = await searchUsers(term);
      if (!users.length) return { content: [{ type: "text", text: `No users found for "${term}"` }] };

      const lines = [
        "ID                         | Username             | Email",
        "---------------------------|----------------------|------",
      ];
      for (const u of users) {
        lines.push(`${u.id} | ${u.username.padEnd(20)} | ${u.email || "-"}`);
      }
      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  // ── mm_create_group_dm ───────────────────────────────────────
  server.tool(
    "mm_create_group_dm",
    "Create a group DM channel with multiple users (by user IDs)",
    {
      user_ids: z.array(z.string()).describe("Array of Mattermost user IDs to include (bot's own ID added automatically)"),
    },
    async ({ user_ids }) => {
      const ch = await createGroupDm(user_ids);
      return {
        content: [{ type: "text", text: `Group DM created (channel id: ${ch.id})` }],
      };
    }
  );

  // ── mm_add_to_channel ────────────────────────────────────────
  server.tool(
    "mm_add_to_channel",
    "Add a user to a channel (public/private/group — does not work on DMs)",
    {
      channel: z.string().describe("Channel name or ID"),
      user_id: z.string().describe("User ID to add"),
    },
    async ({ channel, user_id }) => {
      const chId = await resolveChannel(channel);
      const member = (await api("POST", `/api/v4/channels/${chId}/members`, {
        user_id,
      })) as { channel_id: string; user_id: string };
      return {
        content: [{ type: "text", text: `Added user ${member.user_id} to channel ${member.channel_id}` }],
      };
    }
  );

  // ── mm_categories ──────────────────────────────────────────────
  server.tool(
    "mm_categories",
    "List Mattermost sidebar channel categories with their channels",
    {
      user: z.string().optional().describe("Username to list categories for (default: bot's own)"),
    },
    async ({ user }) => {
      let targetUid: string;
      if (user) {
        const results = (await api("POST", "/api/v4/users/search", { term: user })) as Array<{ id: string; username: string }>;
        if (!results.length) return { content: [{ type: "text", text: `User not found: ${user}` }] };
        targetUid = results[0].id;
      } else {
        targetUid = await getUserId();
      }

      const data = (await api("GET", `/api/v4/users/${targetUid}/teams/${MM_TEAM_ID}/channels/categories`)) as {
        categories: Array<{ display_name: string; type: string; channel_ids: string[] }>;
      };

      // Resolve channel IDs to names
      const channelMap = new Map<string, string>();
      const allChannels = (await api("GET", `/api/v4/users/${targetUid}/teams/${MM_TEAM_ID}/channels`)) as Channel[];
      for (const ch of allChannels) channelMap.set(ch.id, ch.display_name || ch.name);

      const lines: string[] = [];
      for (const cat of data.categories) {
        const names = cat.channel_ids.map((id) => channelMap.get(id) || id);
        lines.push(`## ${cat.display_name} (${cat.type}) — ${names.length} channels`);
        for (const name of names.sort()) lines.push(`  - ${name}`);
        lines.push("");
      }

      return { content: [{ type: "text", text: lines.join("\n") || "(no categories)" }] };
    }
  );
}
