import { ScrollView, StyleSheet } from "react-native";
import { Chip } from "react-native-paper";

import { palette, spacing } from "@/theme/tokens";

export type FilterOption<T extends string> = {
  value: T;
  label: string;
};

type Props<T extends string> = {
  options: readonly FilterOption<T>[];
  value: T;
  onChange: (value: T) => void;
  /** Prefix for test ids, e.g. "region" -> `filter-region-europe`. */
  testIDPrefix?: string;
};

/**
 * A horizontally scrolling single-choice filter row.
 *
 * Used for the region filter on Competitions and for the market/status filters
 * elsewhere, so the selection affordance is identical wherever a list can be
 * narrowed. The row scrolls rather than wrapping, which keeps the header height
 * fixed on a small Android screen.
 */
export function FilterChips<T extends string>({
  options,
  value,
  onChange,
  testIDPrefix = "filter",
}: Props<T>) {
  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      contentContainerStyle={styles.row}
      keyboardShouldPersistTaps="handled"
    >
      {options.map((option) => {
        const selected = option.value === value;
        return (
          <Chip
            key={option.value}
            selected={selected}
            onPress={() => onChange(option.value)}
            style={[styles.chip, selected ? styles.chipSelected : null]}
            textStyle={selected ? styles.textSelected : styles.text}
            accessibilityRole="button"
            accessibilityState={{ selected }}
            accessibilityLabel={
              selected ? `${option.label}, selected` : option.label
            }
            testID={`${testIDPrefix}-${option.value}`}
          >
            {option.label}
          </Chip>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  row: {
    gap: spacing.small,
    paddingHorizontal: spacing.standard,
    paddingVertical: spacing.small,
  },
  chip: {
    backgroundColor: palette.surface,
    borderColor: palette.border,
    borderWidth: 1,
  },
  chipSelected: {
    backgroundColor: palette.primary,
    borderColor: palette.primary,
  },
  text: {
    color: palette.textSecondary,
  },
  textSelected: {
    color: palette.textPrimary,
  },
});
