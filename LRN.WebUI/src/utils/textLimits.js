export const MAX_TEXT_LENGTH = 1500;

export function limitText(value) {
  return String(value || '').slice(0, MAX_TEXT_LENGTH);
}

export function textCountLabel(value) {
  return `${String(value || '').length}/${MAX_TEXT_LENGTH}`;
}
