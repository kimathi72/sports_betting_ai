/**
 * CollapsibleSection behaviour.
 *
 * The contract that matters: the toggle states its own state for assistive
 * technology, a collapsed section renders none of its children, and toggling does
 * not fetch — the component has no data access, which is what makes expanding a
 * section free.
 */
import { fireEvent, render } from "@testing-library/react-native";
import { Text } from "react-native";

import { CollapsibleSection } from "@/components/CollapsibleSection";

describe("CollapsibleSection", () => {
  it("renders its children when expanded", async () => {
    const { getByText } = await render(
      <CollapsibleSection
        title="2026/27"
        expanded
        onToggle={() => {}}
        testID="section"
      >
        <Text>child content</Text>
      </CollapsibleSection>,
    );

    expect(getByText("child content")).toBeTruthy();
  });

  it("renders nothing inside when collapsed", async () => {
    const { queryByText } = await render(
      <CollapsibleSection
        title="2025/26"
        expanded={false}
        onToggle={() => {}}
        testID="section"
      >
        <Text>hidden content</Text>
      </CollapsibleSection>,
    );

    expect(queryByText("hidden content")).toBeNull();
  });

  it("reports expanded state to assistive technology", async () => {
    const { getByTestId, rerender } = await render(
      <CollapsibleSection
        title="2026/27"
        expanded
        onToggle={() => {}}
        testID="section"
      />,
    );

    expect(getByTestId("section").props.accessibilityState).toEqual({
      expanded: true,
    });
    expect(getByTestId("section").props.accessibilityLabel).toContain(
      "expanded",
    );

    await rerender(
      <CollapsibleSection
        title="2026/27"
        expanded={false}
        onToggle={() => {}}
        testID="section"
      />,
    );

    expect(getByTestId("section").props.accessibilityState).toEqual({
      expanded: false,
    });
    expect(getByTestId("section").props.accessibilityLabel).toContain(
      "collapsed",
    );
  });

  it("calls onToggle when the header is pressed", async () => {
    const onToggle = jest.fn();
    const { getByTestId } = await render(
      <CollapsibleSection
        title="2026/27"
        expanded={false}
        onToggle={onToggle}
        testID="section"
      />,
    );

    await fireEvent.press(getByTestId("section"));

    expect(onToggle).toHaveBeenCalledTimes(1);
  });

  it("marks the current season in its label", async () => {
    const { getByTestId } = await render(
      <CollapsibleSection
        title="2026/27"
        expanded
        isCurrent
        onToggle={() => {}}
        testID="section"
      />,
    );

    expect(getByTestId("section").props.accessibilityLabel).toContain(
      "current season",
    );
  });

  it("shows a subtitle when provided and omits it otherwise", async () => {
    const withSubtitle = await render(
      <CollapsibleSection
        title="2024/25"
        subtitle="380 matches"
        expanded={false}
        onToggle={() => {}}
      />,
    );
    expect(withSubtitle.getByText("380 matches")).toBeTruthy();

    const withoutSubtitle = await render(
      <CollapsibleSection
        title="2024/25"
        expanded={false}
        onToggle={() => {}}
      />,
    );
    expect(withoutSubtitle.queryByText("380 matches")).toBeNull();
  });
});
