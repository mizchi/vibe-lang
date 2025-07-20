//! Tests for effect inference

#[cfg(test)]
mod tests {
    use crate::effect_inference::{EffectContext, EffectInference};
    use parser::parse;
    use xs_core::{Effect, EffectRow, EffectSet};

    #[test]
    fn test_pure_expressions() {
        let mut ctx = EffectContext::new();

        // Literals are pure
        let lit = parse("42").unwrap();
        let effects = ctx.infer_effects(&lit).unwrap();
        assert!(effects.is_pure());

        // Variables are pure
        let var = parse("x").unwrap();
        let effects = ctx.infer_effects(&var).unwrap();
        assert!(effects.is_pure());

        // Lambda creation is pure
        let lambda = parse("(fn (x) x)").unwrap();
        let effects = ctx.infer_effects(&lambda).unwrap();
        assert!(effects.is_pure());
    }

    #[test]
    fn test_io_effects() {
        let mut ctx = EffectContext::new();

        // print has IO effect
        let print_expr = parse(r#"(print "hello")"#).unwrap();
        let effects = ctx.infer_effects(&print_expr).unwrap();
        match effects {
            EffectRow::Concrete(set) => {
                assert!(set.contains(&Effect::IO));
            }
            _ => panic!("Expected concrete IO effect"),
        }
    }

    #[test]
    fn test_effect_sequencing() {
        let mut ctx = EffectContext::new();

        // Let-in sequences effects
        let let_in = parse(
            r#"
            (let x (print "hello") in
              (print "world"))
        "#,
        )
        .unwrap();
        let effects = ctx.infer_effects(&let_in).unwrap();
        match effects {
            EffectRow::Concrete(set) => {
                assert!(set.contains(&Effect::IO));
            }
            _ => panic!("Expected concrete IO effect"),
        }
    }

    #[test]
    fn test_conditional_effects() {
        let mut ctx = EffectContext::new();

        // If combines effects from all branches
        let if_expr = parse(
            r#"
            (if true
              (print "yes")
              (error "no"))
        "#,
        )
        .unwrap();
        let effects = ctx.infer_effects(&if_expr).unwrap();
        match effects {
            EffectRow::Concrete(set) => {
                assert!(set.contains(&Effect::IO));
                assert!(set.contains(&Effect::Error));
            }
            _ => panic!("Expected concrete effects"),
        }
    }

    #[test]
    fn test_effect_unification() {
        let mut inference = EffectInference::new();

        // Test unifying concrete effects
        let io = EffectRow::Concrete(EffectSet::single(Effect::IO));
        let state = EffectRow::Concrete(EffectSet::single(Effect::State));

        let var1 = inference.fresh_effect_var();
        let row1 = EffectRow::Variable(var1.clone());

        // Unify variable with concrete effect
        assert!(inference.unify_effects(&row1, &io).unwrap());

        // Check substitution
        let subst = inference.apply_subst(&row1);
        assert_eq!(subst, io);
    }

    #[test]
    fn test_effect_extension() {
        let inference = EffectInference::new();

        // Test extension rows
        let io_set = EffectSet::single(Effect::IO);
        let var = xs_core::EffectVar("ρ".to_string());
        let ext = EffectRow::Extension(io_set.clone(), var.clone());

        // Extension should not be pure
        assert!(!ext.is_pure());

        // Display should show "IO | ρ"
        let display = format!("{}", ext);
        assert!(display.contains("IO"));
        assert!(display.contains("ρ"));
    }
}
