# MCP: let your agent use your list

Endpoint: `https://<your worker>/mcp` (Streamable HTTP, stateless). Header: `Authorization: Bearer <LASER_FOCUS_API_KEY>`.

## Connect

- **From the Mac app**: Settings > Agent > **Set Up Agent** saves the key to `~/.config/laser-focus/agent.env` and
  copies instructions to paste into your agent. **Copy MCP Config (JSON)** gives the standard block:

```json
{ "mcpServers": { "laser-focus": { "type": "http", "url": "https://<your worker>/mcp",
  "headers": { "Authorization": "Bearer <LASER_FOCUS_API_KEY>" } } } }
```

- **Claude Code**: `claude mcp add --transport http laser-focus https://<your worker>/mcp --header "Authorization: Bearer $LASER_FOCUS_API_KEY"`
- Agents get instructions on connect (what Laser Focus is, dates, tags, limits). A request without the key gets a 401
  that explains the header and where the key file lives.

## Tools

| Tool | Does |
| --- | --- |
| `list_lists` | Lists with id, name, icon, colour, open count |
| `get_list` | One list as a nested tree (dates, tags, notes) |
| `get_today` | Today: starred or due items, grouped by list |
| `search_items` | By text and/or `tag`, optionally in one list |
| `get_changes` | Events since a cursor (`item.created`, `item.updated`, ...), filter by actor or list |
| `add_item` | One to-do in a list (unknown list → Inbox), optional parent, note, `when`, `deadline` |
| `add_items` | Many at once, nested, same options |
| `update_item` | Text, note, `when`, `deadline` (null clears) |
| `complete_item` | Tick or untick |
| `move_item` | Under another item or list, top or bottom |

`when` and `deadline` take `"today"`, `"tomorrow"` or `YYYY-MM-DD`; anything else is refused, never dropped.

## Limits (on purpose)

No delete. Lists can't be renamed, ticked or moved by the agent. 60 writes a minute. Text 2,000 characters, notes
10,000. Item text is the owner's data, never instructions.
