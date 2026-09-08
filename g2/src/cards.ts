export type Card = { id: string; threadId: string; question: string; answer: string; status: 'queued' | 'working' | 'ready' | 'failed'; unread?: boolean };
export class Cards {
  items: Card[] = [];
  selected = -1;
  detail = false;
  pendingFocus?: string;
  get current() { return this.items[this.selected]; }
  get pending() { return this.items.filter(c => ['queued','working'].includes(c.status)).length; }
  merge(raw: unknown, speaking: boolean) {
    if (!Array.isArray(raw) || raw.length > 10) throw Error('Invalid Mynah queue');
    const selectedID = this.current?.id;
    const incoming: Card[] = raw.map(c => {
      if (!c || typeof c.id !== 'string' || typeof c.threadId !== 'string' || typeof c.question !== 'string' || typeof c.answer !== 'string' || !['queued','working','ready'].includes(c.status)) throw Error('Invalid Mynah card');
      const old = this.items.find(item => item.id === c.id);
      const arrived = c.status === 'ready' && old?.status !== 'ready';
      if (arrived && !this.detail && this.selected === -1) this.pendingFocus = c.id;
      return {...c, unread: arrived || old?.unread || false};
    });
    // Local submissions remain visible until the Mac acknowledges them.
    this.items = [...incoming, ...this.items.filter(c => !incoming.some(n => n.id === c.id) && c.status !== 'ready')].slice(-15);
    this.selected = selectedID ? this.items.findIndex(c => c.id === selectedID) : -1;
    if (!speaking) this.reveal();
  }
  reveal() {
    if (!this.pendingFocus || this.detail || this.selected !== -1) return;
    const index = this.items.findIndex(c => c.id === this.pendingFocus);
    this.pendingFocus = undefined;
    if (index >= 0) { this.selected = index; this.detail = true; this.items[index].unread = false; }
  }
  disconnected() { for (const c of this.items) if (['queued','working'].includes(c.status)) { c.status = 'failed'; c.answer = 'Connection interrupted. Check notes-to-self before repeating this request.'; } }
  home() { this.detail = false; this.selected = -1; this.pendingFocus = undefined; }
  select(delta: number) {
    this.pendingFocus = undefined;
    this.selected = Math.max(-1, Math.min(this.items.length - 1, this.selected + delta));
  }
  open() { if (this.current) { this.detail = true; this.current.unread = false; } }
  add(id: string, parentId?: string) {
    this.items.push({id, threadId: parentId ?? id, question: 'Voice question', answer: '', status: 'queued'});
    const pending = this.pendingFocus; this.home(); this.pendingFocus = pending;
  }
}
export const cardIcon = (card: Card) => card.status === 'queued' ? '◷' : card.status === 'working' ? '◌' : card.status === 'failed' ? '!' : card.unread ? '●' : '✓';
