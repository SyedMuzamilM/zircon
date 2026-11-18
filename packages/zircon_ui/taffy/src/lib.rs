//! Flex arrangement for one measured Zircon container, in logical pixels.
use taffy::prelude::*;

#[repr(C)]
pub struct Item {
    width: f32,
    height: f32,
    min_width: f32,
    min_height: f32,
    max_width: f32,
    max_height: f32,
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,
    grow: f32,
    shrink: f32,
}

#[repr(C)]
pub struct Bounds {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
}

fn dimension(value: f32) -> Dimension {
    if value.is_finite() && value >= 0.0 {
        length(value)
    } else {
        auto()
    }
}

/// # Safety
/// The caller supplies separate live arrays of `count` input and output elements.
#[no_mangle]
pub unsafe extern "C" fn zircon_taffy_arrange(
    items: *const Item,
    output: *mut Bounds,
    count: usize,
    width: f32,
    height: f32,
    gap: f32,
    row: bool,
    align: u8,
    justify: u8,
) -> bool {
    let items = unsafe { std::slice::from_raw_parts(items, count) };
    let output = unsafe { std::slice::from_raw_parts_mut(output, count) };
    let mut tree: TaffyTree<()> = TaffyTree::with_capacity(count + 1);
    tree.disable_rounding();
    let mut children = Vec::with_capacity(count);
    for item in items {
        let child = Style {
            size: Size {
                width: dimension(item.width),
                height: dimension(item.height),
            },
            min_size: Size {
                width: length(item.min_width),
                height: length(item.min_height),
            },
            max_size: Size {
                width: if item.max_width.is_finite() {
                    length(item.max_width)
                } else {
                    auto()
                },
                height: if item.max_height.is_finite() {
                    length(item.max_height)
                } else {
                    auto()
                },
            },
            margin: Rect {
                left: length(item.left),
                right: length(item.right),
                top: length(item.top),
                bottom: length(item.bottom),
            },
            flex_grow: item.grow,
            flex_shrink: item.shrink,
            ..Default::default()
        };
        let Ok(id) = tree.new_leaf(child) else {
            return false;
        };
        children.push(id);
    }
    let parent = Style {
        size: Size {
            width: length(width),
            height: length(height),
        },
        flex_direction: if row {
            FlexDirection::Row
        } else {
            FlexDirection::Column
        },
        gap: Size {
            width: length(gap),
            height: length(gap),
        },
        align_items: match align {
            0 => AlignItems::START,
            1 => AlignItems::CENTER,
            2 => AlignItems::END,
            3 => AlignItems::STRETCH,
            _ => return false,
        },
        justify_content: match justify {
            0 => JustifyContent::START,
            1 => JustifyContent::CENTER,
            2 => JustifyContent::END,
            3 => JustifyContent::SPACE_BETWEEN,
            _ => return false,
        },
        ..Default::default()
    };
    let Ok(root) = tree.new_with_children(parent, &children) else {
        return false;
    };
    if tree
        .compute_layout(
            root,
            Size {
                width: AvailableSpace::Definite(width),
                height: AvailableSpace::Definite(height),
            },
        )
        .is_err()
    {
        return false;
    }
    for (id, bounds) in children.into_iter().zip(output) {
        let Ok(layout) = tree.layout(id) else {
            return false;
        };
        *bounds = Bounds {
            x: layout.location.x,
            y: layout.location.y,
            width: layout.size.width,
            height: layout.size.height,
        };
    }
    true
}
