// Protobuf may omit CLICK_EVENT because its wire value is zero.
type Input = { eventType?: number; eventSource?: number };
export function inputType(event: { textEvent?: Input; listEvent?: Input; sysEvent?: Input }): number | undefined {
  const container = event.textEvent ?? event.listEvent;
  if (container) return container.eventType ?? 0;
  const system = event.sysEvent;
  if (system?.eventType !== undefined) return system.eventType;
  // An empty system event is not proof of a tap. Require a physical source.
  if (system && [1, 2, 3].includes(system.eventSource ?? -1)) return 0;
  return undefined;
}
