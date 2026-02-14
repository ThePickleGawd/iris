 
declare module "https://cdn.jsdelivr.net/npm/@xenova/transformers@2.17.2" {
  export const env: {
    allowLocalModels: boolean
    useBrowserCache: boolean
    [key: string]: unknown
  }
  export function pipeline(...args: unknown[]): Promise<any>
}
