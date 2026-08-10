import java.io.*;
import java.lang.reflect.*;
import java.util.*;

import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaThread;
import se.krka.kahlua.vm.LuaClosure;

/*
 * Headless test runner for the QoL Compendium.
 *
 * Boots the exact Kahlua VM that Project Zomboid ships, installs a stubbed game API,
 * loads the real mod source, and runs Lua specs against it. Every test gets a fresh
 * environment, so a mod's file-level locals cannot leak between tests.
 *
 * Usage: TestRunner <gameDir> <luaFile> [luaFile ...]
 *   Files load in the given order. Must run with the game directory as the working
 *   directory, because Kahlua resolves stdlib.lua relative to it.
 */
public class TestRunner {

	private static String gameDir;
	private static String modRoot;
	private static final List<String> loadFiles = new ArrayList<String>();
	private static List<String> moodleTypes = new ArrayList<String>();
	private static List<String> characterStats = new ArrayList<String>();
	private static final Map<String, float[]> statBounds = new LinkedHashMap<String, float[]>();
	private static final Map<String, Object> sandboxDefaults = new LinkedHashMap<String, Object>();
	private static int translationFailures = 0;

	public static void main(String[] args) throws Exception {
		if (args.length < 3) {
			System.out.println("usage: TestRunner <gameDir> <modRoot> <luaFile> [luaFile ...]");
			System.exit(2);
		}
		gameDir = args[0];
		modRoot = new File(args[1]).getCanonicalPath();
		for (int i = 2; i < args.length; i++) loadFiles.add(args[i]);

		moodleTypes = readMoodleTypes();
		System.out.println("MoodleType constants found in this build: " + moodleTypes.size());

		characterStats = readCharacterStats();
		System.out.println("CharacterStat constants found in this build: " + characterStats.size());

		int staticFailures = checkConstantUsage("MoodleType.", moodleTypes)
			+ checkConstantUsage("CharacterStat.", characterStats)
			+ checkItemScripts()
			+ checkSandboxOptions()
			+ checkTexturePaths();

		// Discovery pass: load everything once just to learn the test names.
		List<String> names;
		try {
			names = discoverTests();
		} catch (Exception e) {
			System.out.println("FATAL  could not load test environment");
			System.out.println("       " + rootCause(e));
			System.exit(1);
			return;
		}

		System.out.println("Running " + names.size() + " test(s)");
		System.out.println();

		int failures = 0;
		for (int i = 0; i < names.size(); i++) {
			Result r = runSingle(i + 1);
			if (r.ok) {
				System.out.println("  PASS  " + r.name);
			} else {
				failures++;
				System.out.println("  FAIL  " + r.name);
				for (String line : r.error.split("\n")) System.out.println("        " + line);
			}
		}

		System.out.println();
		int total = failures + staticFailures + translationFailures;
		System.out.println(total == 0
			? "ALL " + names.size() + " TEST(S) PASSED"
			: total + " FAILURE(S)");
		System.exit(total == 0 ? 0 : 1);
	}

	/* ---------- environment ---------- */

	private static KahluaTable freshEnv(J2SEPlatform platform) {
		KahluaTable env = platform.newEnvironment();

		KahluaTable types = platform.newTable();
		KahluaTable list = platform.newTable();
		for (int i = 0; i < moodleTypes.size(); i++) {
			String n = moodleTypes.get(i);
			types.rawset(n, n);
			list.rawset(Double.valueOf(i + 1), n);
		}
		env.rawset("MoodleType", types);
		env.rawset("QOLC_MOODLE_TYPES", list);

		// Build 42 moved every named stat accessor onto CharacterStat, so the same
		// treatment applies: names come from the jar, and the real min/max travel with
		// them so the stub can clamp exactly like Stats.set does.
		KahluaTable stats = platform.newTable();
		KahluaTable bounds = platform.newTable();
		for (int i = 0; i < characterStats.size(); i++) {
			String n = characterStats.get(i);
			stats.rawset(n, n);
			float[] b = statBounds.get(n);
			if (b != null) {
				KahluaTable entry = platform.newTable();
				entry.rawset("Min", Double.valueOf(b[0]));
				entry.rawset("Max", Double.valueOf(b[1]));
				entry.rawset("Default", Double.valueOf(b[2]));
				bounds.rawset(n, entry);
			}
		}
		env.rawset("CharacterStat", stats);
		env.rawset("QOLC_STAT_BOUNDS", bounds);

		KahluaTable defaults = platform.newTable();
		for (Map.Entry<String, Object> e : sandboxDefaults.entrySet()) {
			defaults.rawset(e.getKey(), e.getValue());
		}
		env.rawset("QOLC_SANDBOX_DEFAULTS", defaults);

		env.rawset("QOLC_GAME_DIR", gameDir);
		return env;
	}

	private static KahluaThread load(J2SEPlatform platform, KahluaTable env) throws Exception {
		KahluaThread thread = new KahluaThread(System.out, platform, env);
		// PZ's Kahlua fork dereferences this when reporting a Lua error. Left null it
		// throws an NPE that hides the actual failure.
		thread.debugOwnerThread = Thread.currentThread();
		for (String path : loadFiles) {
			File f = new File(path);
			if (isTranslation(f)) {
				loadTranslation(platform, env, f);
				continue;
			}
			InputStream in = new FileInputStream(f);
			try {
				LuaClosure closure = LuaCompiler.loadis(in, f.getName(), env);
				thread.call(closure, new Object[0]);
			} finally {
				in.close();
			}
		}
		return thread;
	}

	private static boolean isTranslation(File f) {
		return f.getName().endsWith(".json") && f.getPath().replace('\\', '/').contains("/Translate/");
	}

	/**
	 * Build 42 translations are flat json, not lua. Keys such as "Base.SlingAFront" or
	 * "Hotbar 16" are perfectly legal there and would be a syntax error if compiled.
	 * Every file merges into one global Translations table, so a spec can look up any
	 * key without caring which file it came from.
	 */
	private static void loadTranslation(J2SEPlatform platform, KahluaTable env, File f) throws IOException {
		Object existing = env.rawget("Translations");
		KahluaTable table = (existing instanceof KahluaTable) ? (KahluaTable) existing : platform.newTable();
		int entries = 0;

		BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(f), "UTF-8"));
		String line;
		try {
			java.util.regex.Pattern entry =
				java.util.regex.Pattern.compile("^\\s*\"(.+?)\"\\s*:\\s*\"(.*)\"\\s*,?\\s*$");
			while ((line = r.readLine()) != null) {
				java.util.regex.Matcher m = entry.matcher(line);
				if (m.find()) {
					// The game runs every translation through String.format, so a bare
					// percent is an invalid conversion and the whole string fails to
					// render. Vanilla writes a literal percent as %%.
					String value = m.group(2);
					if (value.replace("%%", "").indexOf('%') >= 0) {
						System.out.println("  FAIL  unescaped % in translation \"" + m.group(1)
							+ "\"  (" + f.getName() + "), vanilla writes it as %%");
						translationFailures++;
					}
					table.rawset(m.group(1), value);
					entries++;
				}
			}
		} finally {
			r.close();
		}

		env.rawset("Translations", table);
		if (entries == 0) System.out.println("WARN   no entries parsed from " + f.getName());
	}

	private static List<String> discoverTests() throws Exception {
		J2SEPlatform platform = new J2SEPlatform();
		KahluaTable env = freshEnv(platform);
		load(platform, env);

		List<String> names = new ArrayList<String>();
		Object testsObj = env.rawget("Tests");
		if (!(testsObj instanceof KahluaTable)) return names;
		Object regObj = ((KahluaTable) testsObj).rawget("Registered");
		if (!(regObj instanceof KahluaTable)) return names;

		KahluaTable reg = (KahluaTable) regObj;
		for (int i = 1; i <= reg.len(); i++) {
			Object entry = reg.rawget(Double.valueOf(i));
			if (entry instanceof KahluaTable) {
				names.add(String.valueOf(((KahluaTable) entry).rawget("Name")));
			}
		}
		return names;
	}

	private static Result runSingle(int index) {
		Result r = new Result();
		r.name = "test #" + index;
		try {
			J2SEPlatform platform = new J2SEPlatform();
			KahluaTable env = freshEnv(platform);
			KahluaThread thread = load(platform, env);

			Object fn = env.rawget("RunSingleTest");
			if (fn == null) throw new IllegalStateException("RunSingleTest is not defined by the harness");
			thread.call(fn, new Object[] { Double.valueOf(index) });

			Object name = env.rawget("TEST_NAME");
			if (name != null) r.name = String.valueOf(name);
			r.ok = Boolean.TRUE.equals(env.rawget("TEST_OK"));
			Object err = env.rawget("TEST_ERROR");
			r.error = err == null ? "no error reported" : String.valueOf(err);
		} catch (Throwable t) {
			r.ok = false;
			r.error = rootCause(t);
		}
		return r;
	}

	/* ---------- static checks ---------- */

	/** Reads the MoodleType constant names straight out of the shipped jar. */
	private static List<String> readMoodleTypes() {
		List<String> names = new ArrayList<String>();
		try {
			// false = do not run static initialisers, which would need a live game
			Class<?> c = Class.forName("zombie.scripting.objects.MoodleType", false,
				TestRunner.class.getClassLoader());
			for (Field f : c.getDeclaredFields()) {
				if (!Modifier.isStatic(f.getModifiers())) continue;
				if (!f.getName().matches("[A-Z][A-Z0-9_]*")) continue;
				names.add(f.getName());
			}
		} catch (Throwable t) {
			System.out.println("WARN   could not read MoodleType from the jar: " + t);
		}
		return names;
	}

	/**
	 * Reads the CharacterStat constants and their real bounds out of the shipped jar.
	 * Unlike MoodleType this one has to be initialised, because the constants are built
	 * by a static block calling register(id, min, max, default) rather than declared.
	 */
	private static List<String> readCharacterStats() {
		List<String> names = new ArrayList<String>();
		try {
			// true = run the static initialiser. It only fills a HashMap, so it works
			// without a live game.
			Class<?> c = Class.forName("zombie.characters.CharacterStat", true,
				TestRunner.class.getClassLoader());
			Method min = c.getMethod("getMinimumValue");
			Method max = c.getMethod("getMaximumValue");
			Method def = c.getMethod("getDefaultValue");

			for (Field f : c.getDeclaredFields()) {
				if (!Modifier.isStatic(f.getModifiers())) continue;
				if (!f.getType().equals(c)) continue;
				if (!f.getName().matches("[A-Z][A-Z0-9_]*")) continue;

				names.add(f.getName());
				Object v = f.get(null);
				if (v == null) continue;
				statBounds.put(f.getName(), new float[] {
					((Float) min.invoke(v)).floatValue(),
					((Float) max.invoke(v)).floatValue(),
					((Float) def.invoke(v)).floatValue()
				});
			}
		} catch (Throwable t) {
			System.out.println("WARN   could not read CharacterStat from the jar: " + t);
		}
		return names;
	}

	/**
	 * Scans every loaded mod file for <prefix>X references and verifies each one exists
	 * in the installed build. Catches build-41 constant names in branches the tests
	 * never execute, which is how MoodleType.Panic survived into a shipped 42 folder.
	 */
	private static int checkConstantUsage(String prefix, List<String> valid) throws IOException {
		if (valid.isEmpty()) return 0;
		Set<String> known = new HashSet<String>(valid);
		int bad = 0;
		for (String path : loadFiles) {
			File f = new File(path);
			if (!f.getName().endsWith(".lua")) continue;
			// Only shipped mod source. Specs and stubs deliberately name retired
			// constants and placeholder textures.
			if (!isShippedSource(f)) continue;
			BufferedReader r = new BufferedReader(new FileReader(f));
			String line;
			int n = 0;
			try {
				while ((line = r.readLine()) != null) {
					n++;
					// Comments are prose and routinely name a retired constant to explain
					// why it is gone. Only real code is checked.
					int comment = line.indexOf("--");
					if (comment >= 0) line = line.substring(0, comment);

					int at = 0;
					while ((at = line.indexOf(prefix, at)) >= 0) {
						at += prefix.length();
						int end = at;
						while (end < line.length()
							&& (Character.isLetterOrDigit(line.charAt(end)) || line.charAt(end) == '_')) end++;
						String name = line.substring(at, end);
						if (name.length() > 0 && !known.contains(name)) {
							bad++;
							System.out.println("  FAIL  unknown " + prefix + name
								+ "  (" + f.getName() + ":" + n + ")");
						}
					}
				}
			} finally {
				r.close();
			}
		}
		if (bad > 0) System.out.println();
		return bad;
	}

	/**
	 * Checks mod item scripts against the shape build 42 actually uses. Every one of
	 * these was a real crash: a legacy "Type" leaves getItemType() null and takes the
	 * debug item spawner down, an un-namespaced BodyLocation never resolves, and
	 * DisplayName is simply ignored so the item shows as its id.
	 */
	private static int checkItemScripts() throws IOException {
		File scripts = new File(modRoot, "42/media/scripts");
		if (!scripts.isDirectory()) return 0;

		java.util.ArrayDeque<File> queue = new java.util.ArrayDeque<File>();
		queue.add(scripts);
		int bad = 0;

		while (!queue.isEmpty()) {
			File dir = queue.poll();
			File[] children = dir.listFiles();
			if (children == null) continue;

			for (File f : children) {
				if (f.isDirectory()) { queue.add(f); continue; }
				if (!f.getName().endsWith(".txt")) continue;

				BufferedReader r = new BufferedReader(new FileReader(f));
				String line;
				int n = 0;
				boolean inItem = false;
				boolean sawItemType = false;
				String itemName = null;
				int itemLine = 0;

				try {
					while ((line = r.readLine()) != null) {
						n++;
						String t = line.trim();

						// A real item definition is "item Name" and nothing else. Recipe
						// ingredients read "item 1 tags[...]," and must not match.
						if (t.matches("item\\s+[A-Za-z_][A-Za-z0-9_.]*")) {
							inItem = true;
							sawItemType = false;
							itemName = t.substring(5).trim();
							itemLine = n;
							continue;
						}
						if (!inItem) continue;

						if (t.startsWith("}")) {
							if (!sawItemType) {
								bad++;
								System.out.println("  FAIL  item " + itemName + " has no ItemType"
									+ "  (" + f.getName() + ":" + itemLine + ")");
							}
							inItem = false;
							continue;
						}
						if (t.replaceAll("\\s", "").startsWith("ItemType=")) sawItemType = true;

						if (t.replaceAll("\\s", "").startsWith("Type=")) {
							bad++;
							System.out.println("  FAIL  legacy 'Type =' in item " + itemName
								+ ", build 42 wants ItemType  (" + f.getName() + ":" + n + ")");
						}
						if (t.replaceAll("\\s", "").startsWith("DisplayName=")) {
							bad++;
							System.out.println("  FAIL  DisplayName in item " + itemName
								+ ", build 42 takes names from Items_EN  (" + f.getName() + ":" + n + ")");
						}
						java.util.regex.Matcher body = java.util.regex.Pattern
							.compile("^BodyLocation\\s*=\\s*([^,]+),?").matcher(t);
						if (body.find() && !body.group(1).contains(":")) {
							bad++;
							System.out.println("  FAIL  BodyLocation '" + body.group(1).trim()
								+ "' is not namespaced  (" + f.getName() + ":" + n + ")");
						}
					}
				} finally {
					r.close();
				}
			}
		}

		if (bad > 0) System.out.println();
		return bad;
	}

	/**
	 * Checks the sandbox option file against what the game's parser actually accepts,
	 * and against the translation file. A typo in a type or a missing label does not
	 * crash: the option is dropped or renders as its raw key, which is easy to ship
	 * without noticing. Every option is server-controlled balance, so a dropped one
	 * silently falls back to the hardcoded default on every machine.
	 */
	private static int checkSandboxOptions() throws IOException {
		File options = new File(modRoot, "42/media/sandbox-options.txt");
		if (!options.isFile()) return 0;

		// zombie.sandbox.CustomSandboxOptions.parseOption accepts exactly these.
		Set<String> types = new HashSet<String>(
			Arrays.asList("boolean", "double", "enum", "integer", "string"));

		String body = readAll(options);
		// The parser strips /* */ before reading, so the checks here must too.
		body = body.replaceAll("(?s)/\\*.*?\\*/", "");

		int bad = 0;
		if (!body.matches("(?s).*\\bVERSION\\s*=\\s*\\d+.*")) {
			bad++;
			System.out.println("  FAIL  sandbox-options.txt has no VERSION, the parser throws on load");
		}

		Set<String> keys = readTranslationKeys(
			new File(modRoot, "42/media/lua/shared/Translate/EN/Sandbox.json"));

		java.util.regex.Matcher m = java.util.regex.Pattern
			.compile("option\\s+([A-Za-z_][\\w.]*)\\s*\\{(.*?)\\}", java.util.regex.Pattern.DOTALL)
			.matcher(body);

		int found = 0;
		while (m.find()) {
			found++;
			String id = m.group(1);
			String block = m.group(2).replaceAll("\\s", "");

			String type = valueOf(block, "type");
			if (type == null || !types.contains(type)) {
				bad++;
				System.out.println("  FAIL  option " + id + " has type '" + type
					+ "', the parser only accepts " + types);
			}

			String page = valueOf(block, "page");
			if (page != null && !keys.isEmpty() && !keys.contains("Sandbox_" + page)) {
				bad++;
				System.out.println("  FAIL  option " + id + " is on page '" + page
					+ "' but Sandbox.json has no Sandbox_" + page);
			}

			// Hand the declared defaults to the specs, so the stub never has to restate
			// numbers that live in the option file.
			String def = valueOf(block, "default");
			String shortId = id.contains(".") ? id.substring(id.indexOf('.') + 1) : id;
			if (def != null) {
				if ("boolean".equals(type)) sandboxDefaults.put(shortId, Boolean.valueOf(def));
				else if ("string".equals(type) || "enum".equals(type)) sandboxDefaults.put(shortId, def);
				else sandboxDefaults.put(shortId, Double.valueOf(def));
			}

			String translation = valueOf(block, "translation");
			if (translation == null) {
				bad++;
				System.out.println("  FAIL  option " + id + " declares no translation");
			} else if (!keys.isEmpty() && !keys.contains("Sandbox_" + translation)) {
				bad++;
				System.out.println("  FAIL  option " + id + " has no Sandbox_" + translation
					+ " in Sandbox.json, it would render as the raw key");
			}
		}

		if (found == 0) {
			bad++;
			System.out.println("  FAIL  sandbox-options.txt parsed to zero options");
		}
		if (bad > 0) System.out.println();
		return bad;
	}

	/**
	 * Resolves every getTexture path in shipped mod source against the files that
	 * actually exist, in the mod first and then the game install. A wrong path is not an
	 * error at runtime: getTexture returns null and the image simply never draws, which
	 * is easy to miss on a small icon and impossible to miss on a full screen overlay.
	 *
	 * Mod textures live under common/media or 42/media, and the game resolves a path
	 * like "media/textures/GUI/x.png" against both.
	 */
	private static int checkTexturePaths() throws IOException {
		java.util.regex.Pattern call = java.util.regex.Pattern
			.compile("getTexture\\s*\\(\\s*\"([^\"]+)\"");
		int bad = 0;

		for (String path : loadFiles) {
			File f = new File(path);
			if (!f.getName().endsWith(".lua")) continue;
			if (!isShippedSource(f)) continue;

			BufferedReader r = new BufferedReader(new FileReader(f));
			String line;
			int n = 0;
			try {
				while ((line = r.readLine()) != null) {
					n++;
					int comment = line.indexOf("--");
					if (comment >= 0) line = line.substring(0, comment);

					java.util.regex.Matcher m = call.matcher(line);
					while (m.find()) {
						String texture = m.group(1);
						if (resolveTexture(texture)) continue;
						bad++;
						System.out.println("  FAIL  texture not found: " + texture
							+ "  (" + f.getName() + ":" + n + ")");
					}
				}
			} finally {
				r.close();
			}
		}

		if (bad > 0) System.out.println();
		return bad;
	}

	/** True when a "media/..." path exists in the mod's own trees or in the game. */
	private static boolean resolveTexture(String texture) {
		String relative = texture.startsWith("media/") ? texture.substring("media/".length()) : texture;

		File[] roots = {
			new File(modRoot, "common/media"),
			new File(modRoot, "42/media"),
			new File(gameDir, "media")
		};
		for (File root : roots) {
			if (new File(root, relative).isFile()) return true;
		}
		return false;
	}

	/**
	 * True for a file the mod actually ships, which is everything under its common and
	 * version folders. The test tree sits under the same root and is deliberately full
	 * of retired constants and placeholder texture paths, so it is not mod source.
	 */
	private static boolean isShippedSource(File f) throws IOException {
		String path = f.getCanonicalPath();
		return path.startsWith(new File(modRoot, "common").getCanonicalPath())
			|| path.startsWith(new File(modRoot, "42").getCanonicalPath());
	}

	private static String valueOf(String block, String key) {
		java.util.regex.Matcher m = java.util.regex.Pattern
			.compile("(?:^|,)" + key + "=([^,}]+)").matcher(block);
		return m.find() ? m.group(1) : null;
	}

	private static Set<String> readTranslationKeys(File f) throws IOException {
		Set<String> keys = new HashSet<String>();
		if (!f.isFile()) return keys;
		java.util.regex.Matcher m = java.util.regex.Pattern
			.compile("\"(.+?)\"\\s*:").matcher(readAll(f));
		while (m.find()) keys.add(m.group(1));
		return keys;
	}

	private static String readAll(File f) throws IOException {
		StringBuilder sb = new StringBuilder();
		BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(f), "UTF-8"));
		try {
			String line;
			while ((line = r.readLine()) != null) sb.append(line).append('\n');
		} finally {
			r.close();
		}
		return sb.toString();
	}

	private static String rootCause(Throwable t) {
		Throwable c = t;
		while (c.getCause() != null) c = c.getCause();
		return c.toString();
	}

	private static class Result {
		String name;
		boolean ok;
		String error = "";
	}
}
