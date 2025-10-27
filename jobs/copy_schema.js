const util = require("util");
const execFile = util.promisify(require("child_process").execFile);
const path = require("path");

async function exec_schema_migration() {
  const path = require("path");

const script = path.resolve(process.cwd(), "scripts", "pgdump_schema_table_azure_to_dock_node.sh");

  try {
    const { stdout, stderr } = await execFile(script);

    console.log("\nstdout");
    console.log(stdout);

    console.log("\nstderr");
    console.log(stderr);
  } catch (error) {
    console.log("\nerror");
    console.log(error);
  }
}

module.exports = exec_schema_migration;
