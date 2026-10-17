export function originPattern(origin: string, firefox: boolean) {
  const url = new URL(origin);
  if (firefox) url.port = '';
  return url.origin + '/*';
}
