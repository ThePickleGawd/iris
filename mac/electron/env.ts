import dotenv from "dotenv"
import path from "node:path"

// Resolve repository root from mac/dist-electron or mac/electron.
const repoRoot = path.resolve(__dirname, "../..")
const rootEnvPath = path.join(repoRoot, ".env")

dotenv.config({ path: rootEnvPath })

