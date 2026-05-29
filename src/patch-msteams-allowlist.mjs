#!/usr/bin/env node
// PERMANENT FIX: extend the @openclaw/msteams plugin's Bot Framework serviceUrl
// allowlist to include directline.botframework.com so that Direct Line / Web
// Chat replies are not blocked by the plugin's SSRF guard.
//
// Upstream allowlist (graph-users-*.js BOT_FRAMEWORK_SERVICE_URL_HOST_ALLOWLIST)
// only covers Microsoft Teams channel serviceUrls:
//   smba.trafficmanager.net
//   smba.infra.gcc.teams.microsoft.com
//   smba.infra.gov.teams.microsoft.us
//   smba.infra.dod.teams.microsoft.us
//
// When the bot is reached via Direct Line / Web Chat, activities carry
// serviceUrl=https://directline.botframework.com/ which the plugin's
// normalizeBotFrameworkServiceUrl() rejects with
//   "Blocked Microsoft Teams serviceUrl host: directline.botframework.com"
// causing every reply to be silently swallowed inside the streaming pipeline.
//
// This patch is idempotent (marker string prevents re-application) and uses a
// regex with flexible whitespace matching so it tolerates minor formatting
// differences between bundle versions.
//
// Once the upstream @openclaw/msteams plugin extends its allowlist (or exposes
// a public hook), this script can be deleted.

import fs from "node:fs";
import path from "node:path";

const DIST_DIR = "/root/.openclaw/npm/node_modules/@openclaw/msteams/dist";

const patches = [
	{
		name: "extend-bot-framework-serviceurl-allowlist",
		filePattern: /^graph-users-.*\.js$/,
		marker: "__patched_serviceurl_allowlist",
		regex: /(const BOT_FRAMEWORK_SERVICE_URL_HOST_ALLOWLIST = normalizeHostnameSuffixAllowlist\(\[\s*"smba\.trafficmanager\.net",)/,
		replacement: `/* __patched_serviceurl_allowlist */ $1 "directline.botframework.com", "europe.directline.botframework.com",`,
	},
];

function patchFile(filePath, patch) {
	const content = fs.readFileSync(filePath, "utf8");
	if (content.includes(patch.marker)) {
		console.log(`[patch-msteams-allowlist] SKIP ${patch.name} (already patched) in ${path.basename(filePath)}`);
		return false;
	}
	const matched = content.match(patch.regex);
	if (!matched) {
		console.log(`[patch-msteams-allowlist] MISS ${patch.name} (regex not found) in ${path.basename(filePath)}`);
		return false;
	}
	const updated = content.replace(patch.regex, patch.replacement);
	if (updated === content) {
		console.log(`[patch-msteams-allowlist] NOOP ${patch.name} in ${path.basename(filePath)}`);
		return false;
	}
	fs.writeFileSync(filePath, updated, "utf8");
	console.log(`[patch-msteams-allowlist] OK ${patch.name} in ${path.basename(filePath)} (matched ${matched[0].length} chars)`);
	return true;
}

if (!fs.existsSync(DIST_DIR)) {
	console.log(`[patch-msteams-allowlist] dist dir missing: ${DIST_DIR}`);
	process.exit(0);
}

const files = fs.readdirSync(DIST_DIR);
console.log(`[patch-msteams-allowlist] dist files: ${files.filter((f) => /^graph-users-.*\.js$/.test(f)).join(", ")}`);
let totalPatched = 0;
let totalMissed = 0;
for (const patch of patches) {
	const matches = files.filter((f) => patch.filePattern.test(f));
	if (matches.length === 0) {
		console.log(`[patch-msteams-allowlist] no files match pattern ${patch.filePattern} for patch ${patch.name}`);
		totalMissed++;
		continue;
	}
	let patchedAny = false;
	for (const f of matches) {
		const full = path.join(DIST_DIR, f);
		if (patchFile(full, patch)) {
			patchedAny = true;
			totalPatched++;
			break; // pattern is unique, so first hit is enough
		}
	}
	if (!patchedAny) totalMissed++;
}
console.log(`[patch-msteams-allowlist] applied ${totalPatched} patch(es), missed ${totalMissed}`);
