// All tools in one place, plus the rule that turns the owner's settings into a
// policy: read tools run, write tools ask, destructive and execute tools always ask.

import type { CompanionConfig, ToolPolicy } from "../config.ts";
import { extractText } from "./documents.ts";
import { FILE_TOOLS } from "./files.ts";
import { openApp, runCommand } from "./processes.ts";
import { analyzeProject } from "./project.ts";
import type { ToolDefinition } from "./types.ts";

export const ALL_TOOLS: readonly ToolDefinition[] = [...FILE_TOOLS, extractText, analyzeProject, openApp, runCommand];

export function toolMap(tools: readonly ToolDefinition[] = ALL_TOOLS): Map<string, ToolDefinition> {
  return new Map(tools.map((tool) => [tool.name, tool]));
}

export function effectivePolicy(tool: ToolDefinition, config: CompanionConfig): ToolPolicy {
  const override = config.policy.tools[tool.name];
  if (override === "deny") return "deny";
  if (tool.risk === "destructive" || tool.risk === "execute") return "ask";
  if (override === "allow" || override === "ask") return override;
  return tool.risk === "read" ? "allow" : "ask";
}
