//! Viewport and device-pixel-ratio handling.
//!
//! Where the remote viewport sits in a local view (aspect-fit letterboxing), mapping local
//! points to viewport CSS px, and the viewport a "Fit to window" asks for.

use omnigent_protocol::remote_browser::Viewport;

use super::input::{MAX_DPR, MAX_VIEWPORT_EDGE, MIN_DPR, MIN_VIEWPORT_EDGE};

/// Where the video sits inside a local view, in the view's points.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Placement {
    /// Left edge.
    pub x: f64,
    /// Top edge.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
    /// View points per viewport CSS px.
    pub scale: f64,
}

/// Aspect-fits `viewport` into a `view_width` × `view_height` view, centred. `None` for an empty
/// view or viewport.
#[must_use]
pub fn place(viewport: &Viewport, view_width: f64, view_height: f64) -> Option<Placement> {
    let (w, h) = (f64::from(viewport.w), f64::from(viewport.h));
    if !(view_width.is_finite() && view_height.is_finite())
        || view_width <= 0.0
        || view_height <= 0.0
        || w <= 0.0
        || h <= 0.0
    {
        return None;
    }
    let scale = (view_width / w).min(view_height / h);
    let (width, height) = (w * scale, h * scale);
    Some(Placement {
        x: (view_width - width) / 2.0,
        y: (view_height - height) / 2.0,
        width,
        height,
        scale,
    })
}

impl Placement {
    /// The viewport CSS px under a view point, or `None` in the letterbox bars.
    #[must_use]
    pub fn to_viewport(&self, x: f64, y: f64) -> Option<(f64, f64)> {
        let (local_x, local_y) = (x - self.x, y - self.y);
        if !(0.0..=self.width).contains(&local_x) || !(0.0..=self.height).contains(&local_y) {
            return None;
        }
        Some((local_x / self.scale, local_y / self.scale))
    }

    /// Like [`Self::to_viewport`], but clamps points in the bars to the nearest edge (for drags
    /// that leave the video).
    #[must_use]
    pub fn to_viewport_clamped(&self, x: f64, y: f64) -> (f64, f64) {
        let local_x = (x - self.x).clamp(0.0, self.width);
        let local_y = (y - self.y).clamp(0.0, self.height);
        (local_x / self.scale, local_y / self.scale)
    }
}

/// The viewport "Fit to window" requests for a view of `view_width` × `view_height` points: the
/// view size in CSS px, clamped to the protocol bounds, at DPR 1, or 2 for "sharp text".
#[must_use]
pub fn fit_to_window(view_width: f64, view_height: f64, sharp_text: bool) -> Option<Viewport> {
    if !(view_width.is_finite() && view_height.is_finite()) || view_width < 1.0 || view_height < 1.0
    {
        return None;
    }
    let edge = |value: f64| {
        let clamped = value
            .round()
            .clamp(f64::from(MIN_VIEWPORT_EDGE), f64::from(MAX_VIEWPORT_EDGE));
        // Parsing the rounded, clamped value converts it without an `as` cast.
        format!("{clamped:.0}").parse::<u32>().ok()
    };
    Some(Viewport {
        w: edge(view_width)?,
        h: edge(view_height)?,
        dpr: if sharp_text { 2.0 } else { 1.0 },
    })
}

/// The viewport "Mobile size" requests (design doc section 16.1).
///
/// The view in points as CSS px at the screen's scale, clamped to the protocol bounds: a view
/// under 200 points, such as a landscape phone with the keyboard up, gets a slightly larger
/// page, letterboxed.
#[must_use]
pub fn match_view(view_width: f64, view_height: f64, screen_scale: f64) -> Option<Viewport> {
    if !screen_scale.is_finite() {
        return None;
    }
    let viewport = fit_to_window(view_width, view_height, false)?;
    Some(Viewport {
        dpr: screen_scale.clamp(MIN_DPR, MAX_DPR),
        ..viewport
    })
}

/// Device pixels of the encoded video for `viewport` at encode `scale`.
#[must_use]
pub fn video_pixels(viewport: &Viewport, scale: f64) -> (f64, f64) {
    let factor = viewport.dpr * scale;
    (
        f64::from(viewport.w) * factor,
        f64::from(viewport.h) * factor,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const VIEWPORT: Viewport = Viewport {
        w: 1280,
        h: 800,
        dpr: 1.0,
    };

    #[test]
    fn letterboxes_and_maps_points_back_to_css_px() {
        let placement = place(&VIEWPORT, 640.0, 600.0).unwrap();
        assert!((placement.scale - 0.5).abs() < 1e-9);
        assert!((placement.y - 100.0).abs() < 1e-9);
        assert_eq!(placement.to_viewport(320.0, 300.0), Some((640.0, 400.0)));
        assert_eq!(placement.to_viewport(320.0, 50.0), None);
        assert_eq!(placement.to_viewport_clamped(320.0, 50.0), (640.0, 0.0));
        assert!(place(&VIEWPORT, 0.0, 10.0).is_none());
    }

    #[test]
    fn fit_to_window_clamps_and_picks_the_dpr() {
        assert_eq!(
            fit_to_window(1440.4, 899.6, true),
            Some(Viewport {
                w: 1440,
                h: 900,
                dpr: 2.0
            })
        );
        assert_eq!(fit_to_window(100.0, 9000.0, false).unwrap().w, 200);
        assert_eq!(fit_to_window(100.0, 9000.0, false).unwrap().h, 3840);
        assert!(fit_to_window(f64::NAN, 1.0, false).is_none());
        assert_eq!(video_pixels(&VIEWPORT, 0.5), (640.0, 400.0));
    }

    #[test]
    fn match_view_uses_points_and_the_screen_scale() {
        assert_eq!(
            match_view(393.0, 659.6, 3.0),
            Some(Viewport {
                w: 393,
                h: 660,
                dpr: 3.0
            })
        );
        let landscape_with_keyboard = match_view(852.0, 120.0, 3.0).unwrap();
        assert_eq!(
            (landscape_with_keyboard.w, landscape_with_keyboard.h),
            (852, 200)
        );
        assert!((match_view(1180.0, 820.0, 4.0).unwrap().dpr - 3.0).abs() < f64::EPSILON);
        assert!((match_view(1180.0, 820.0, 0.5).unwrap().dpr - 1.0).abs() < f64::EPSILON);
        assert!(match_view(0.0, 820.0, 2.0).is_none());
        assert!(match_view(390.0, 820.0, f64::NAN).is_none());
    }
}
