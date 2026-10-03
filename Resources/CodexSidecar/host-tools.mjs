/* Dynamic tools implemented by the native FloatyTerm host. Extend both this
 * registry and CodexHostTools.swift when adding a capability. No shell tools. */
const pathSchema = { type: 'object', properties: { path: { type: 'string', minLength: 1, maxLength: 4096, description: 'Existing workspace path, relative to the conversation folder or absolute within it.' } }, required: ['path'], additionalProperties: false };
export const hostToolSpecs = [
  { type: 'function', name: 'floatyterm_get_context', description: 'Get the current FloatyTerm conversation folder, channel, session, model, permission mode and view state. Does not read file contents.', inputSchema: { type: 'object', properties: {}, additionalProperties: false } },
  { type: 'function', name: 'floatyterm_reveal_path', description: 'Reveal an existing file or directory inside the conversation workspace in Finder.', inputSchema: pathSchema },
  { type: 'function', name: 'floatyterm_open_file', description: 'Open an existing workspace Markdown or image file in a FloatyTerm viewer tab. Supports md, markdown, mdown, mkd, mdx, png, jpg, jpeg, gif, bmp, tiff, tif, heic, heif, webp, ico and icns. Does not execute files.', inputSchema: pathSchema },
];
const tools = new Map(hostToolSpecs.map(spec => [spec.name, spec]));
export function hostToolArguments(tool, namespace, value) {
  if (namespace != null && namespace !== '') throw new Error('This host tool has no namespace.');
  if (!tools.has(tool)) throw new Error(`Host tool ${tool || 'unknown'} is not registered.`);
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Tool arguments must be an object.');
  const keys = Object.keys(value);
  if (tool === 'floatyterm_get_context') {
    if (keys.length) throw new Error('Context takes no arguments.');
    return {};
  }
  if (keys.some(key => key !== 'path') || typeof value.path !== 'string' || !value.path.trim() || value.path.length > 4096 || value.path.includes('\0')) throw new Error('An existing workspace path is required.');
  return { path: value.path };
}
export const toolResult = (success, value) => ({ success, contentItems: [{ type: 'inputText', text: typeof value === 'string' ? value : JSON.stringify(value) }] });
