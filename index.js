("use strict");
// require("dotenv").config();
const db = require("./db/pg-pool");
const { exec_schema_migration } = require("./jobs");

async function run_job(env_arg_1) {
  switch (env_arg_1) {
    case "SME00445":
      const db_sys = await db.any("SELECT * FROM systems WHERE id = $1", [
        env_arg_1,
      ]);
      console.log("\nSYSTEM: env_arg_1\n");
      console.log(db_sys);
      break;
    case "schema_migration":
      await exec_schema_migration();
      break;

    default:
      console.log("DEFAULT VALUE");
      break;
  }
}

async function on_boot() {
  const env_arg_1 = process.argv[4];

  console.log("\nprocess.argv");
  console.log(process.argv);

  await run_job(env_arg_1);
}
on_boot();
