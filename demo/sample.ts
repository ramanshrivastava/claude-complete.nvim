import { z } from "zod";

const ConfigSchema = z.object({
  port: z.number(),
  host: z.string(),
  retries: z.number().default(3),
});

type Config = z.infer<typeof ConfigSchema>;

// Parse a raw JSON string and validate it against ConfigSchema.
export function parseConfig(raw: string): Config {

}
