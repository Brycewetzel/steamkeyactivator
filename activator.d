import core.runtime;
import core.thread;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.conv;
import std.datetime.systime;
import std.file;
import std.json;
import std.net.curl;
import std.path;
import std.stdio : stderr, File;
import std.string;
import std.typecons;

import ae.sys.file;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.regex;
import ae.utils.time;

import net;

void activateHBProducts()
{
	auto hbKeys =
		(cast(string)cachedGet("https://www.humblebundle.com/home/keys"))
		.extractCapture(re!`var gamekeys =  (\[[^\]]*\]);`)
		.front
		.to!(string[]);
	stderr.writefln!"Got %d HumbleBundle keys"(hbKeys.length);

	activateHBKeys(hbKeys);
}

struct SteamKey
{
	string key;
	string name;

	string toString() { return name ? format!"%s (%s)"(key, name) : key; }
}

void activateHBKeys(string[] hbKeys)
{
	SteamKey[] steamKeys;
	foreach (n, hbKey; hbKeys)
	{
		stderr.writefln!"[%d/%d] Fetching Steam keys for HB product key: %s"(n+1, hbKeys.length, hbKey);
		auto res = cachedGet(cast(string)("https://www.humblebundle.com/api/v1/order/" ~ hbKey ~ "?all_tpkds=true"));
		if (verbose) stderr.writeln("\t", cast(string)res);
		auto j = parseJSON(cast(string)res);
		foreach (tpk; j["tpkd_dict"]["all_tpks"].array)
			if (tpk["key_type"].str == "steam" && "redeemed_key_val" in tpk.object)
			{
				auto steamKey = tpk["redeemed_key_val"].str;
				if (!steamKey.canFind("<a href"))
				{
					stderr.writeln("\t", "Found Steam key: ", steamKey);
					steamKeys ~= SteamKey(steamKey, "human_name" in tpk ? tpk["human_name"].str : null);
				}
			}
	}

	activateSteamKeys(steamKeys);
}

void activateSteamKeys(SteamKey[] steamKeys)
{
	auto sessionID =
		(cast(string)cachedGet("https://store.steampowered.com/account/registerkey"))
		.extractCapture(re!`var g_sessionID = "([^"]*)";`)
		.front;
	stderr.writeln("Got Steam session ID: ", sessionID);

	enum resultFile = "results.txt";
	string[][] results;
	if (resultFile.exists)
		results = resultFile.readText.splitLines.map!(s => s.split("\t")).array;

	foreach (n, key; steamKeys)
	{
		stderr.writefln!"[%d/%d] Activating Steam key: %s"(n+1, steamKeys.length, key);
		if (results.canFind!(result => result[0] == key.key))
		{
			stderr.writeln("\t", "Already activated (", results.find!(result => result[0] == key.key).front[1], ")");
			continue;
		}

		StdTime epoch = 0;
		while (true)
		{
			auto res = cachedPost("https://store.steampowered.com/account/ajaxregisterkey/", "product_key=" ~ key.key ~ "&sessionid=" ~ sessionID, epoch);
			if (verbose) stderr.writeln("\t", cast(string)res);
			auto j = parseJSON(cast(string)res);
			auto code = j["purchase_result_details"].integer;
			switch (code)
			{
				case 0:
					stderr.writeln("\t", "Activated successfully!");
					File(resultFile, "a").writefln!"%s\t%s\t%s"(key.key, "Activated", key.name);
					break;
				case 9:
					stderr.writeln("\t", "Already have this product");
					File(resultFile, "a").writefln!"%s\t%s\t%s"(key.key, "Already owned", key.name);
					break;
				case 53:
					stderr.writeln("\t", "Throttled, waiting...");
					Thread.sleep(5.minutes);
					epoch = Clock.currStdTime;
					continue;
				default:
					throw new Exception("Unknown code: " ~ text(code));
			}
			break;
		}
	}
}

struct Activator
{
static:
	@(`Activate all Steam keys from your HumbleBundle library`)
	void humbleBundle()
	{
		activateHBProducts();
	}

	@(`Activate Steam keys from HumbleBundle product keys from file`)
	void hbKeys(
		Parameter!(string, "Text file containing HumbleBundle product keys, one per line") fileName
	)
	{
		activateHBKeys(readText(fileName).splitLines);
	}

	@(`Activate Steam keys from file`)
	void steamKeys(
		Parameter!(string, "Text file containing Steam keys, one per line") fileName
	)
	{
		activateSteamKeys(readText(fileName).splitLines.map!(line => SteamKey(line)).array);
	}
}

void activator(
	bool verbose,
	Parameter!(string, "Action to perform (see list below)") action = null,
	immutable(string)[] actionArguments = null,
)
{
	net.verbose = verbose;

	static void usageFun(string usage)
	{
		if (usage.canFind("ACTION [ACTION-ARGUMENTS]"))
		{
			stderr.writefln!"%-(%s\n%)\n"(
				getUsageFormatString!activator.format(Runtime.args[0]).splitLines() ~
				usage.splitLines()[1..$]
			);
		}
		else
			stderr.writeln(usage);
	}

	return funoptDispatch!(Activator, FunOptConfig.init, usageFun)([thisExePath] ~ (action ? [action.value] ~ actionArguments : []));
}

mixin main!(funopt!activator);
