// Port (public build): upstream's DOM minis (mascot/minibots.ts) are never
// used by the port (lib/minibots.ts and MiniBot.qml are); lib/build.mjs
// resolves `mascot/minibots` here for --public so none of it is bundled.

const unused = (): never => { throw new Error("mascot/minibots is not part of the port (lib/minibots.ts)"); };
export const createMiniBot = (..._a: unknown[]): HTMLElement => unused();
export const releaseMiniBot = (..._a: unknown[]): void => unused();
export const pruneMiniBots = (): void => {};
export const syncMiniBotStates = (..._a: unknown[]): void => {};
export const tickMiniBots = (..._a: unknown[]): void => {};
export const miniBotCount = () => 0;
