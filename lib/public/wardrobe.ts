// Port (public build): no wardrobe. lib/build.mjs resolves `mascot/wardrobe`
// here for --public: the outfits are the Coucou mascot's, so there are none; what the rest
// of Coucou reads from the wardrobe (core/state.ts's default, the island's and
// the desktop's season cache, the in-island wardrobe's texts) says "none".

import { t } from "@coucou/i18n/i18n";

/** No outfits to pick. */
export const OUTFIT_SELECTIONS: readonly string[] = [];

export type OutfitSelection = string;
export type Outfit = string;

export const DEFAULT_OUTFIT: OutfitSelection = "none";

export const OUTFIT_KEYS: Record<string, string> = { none: "None" };
export const OUTFIT_LABELS: Record<string, string> = {
  get none() { return t("None"); },
};

export const WARDROBE_STRINGS = {
  get title() { return t("Wardrobe"); },
  get autoBadge() { return ""; },
  autoNow: (_current: string) => "",
  autoHover: (_current: string) => "",
};

export function parseOutfit(_raw: unknown): OutfitSelection {
  return "none";
}

export function seasonalOutfit(_date: Date): Outfit {
  return "none";
}

export function resolveOutfit(_selection: OutfitSelection, _date: Date): Outfit {
  return "none";
}

export function wardrobeHeader(_hovered: OutfitSelection | null, _selection: OutfitSelection, _date: Date): string {
  return "";
}

export class SeasonCache {
  get(_selection: OutfitSelection, _date?: Date): Outfit {
    return "none";
  }
}
