package config

import "testing"

func TestEffectiveChargeLimit(t *testing.T) {
    tests := []struct{
        name        string
        user        int
        system      int
        def         int
        want        int
    }{
        {"user overrides system", 75, 90, 80, 75},
        {"system used when no user", 0, 90, 80, 90},
        {"default used when none set", 0, 0, 80, 80},
        {"clamps low values", 10, 0, 0, 40},
        {"clamps high values", 150, 0, 0, 100},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got := EffectiveChargeLimit(tt.user, tt.system, tt.def)
            if got != tt.want {
                t.Fatalf("got %d, want %d", got, tt.want)
            }
        })
    }
}

