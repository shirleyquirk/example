"""Draws the divider schematics in this folder (docs only).
   pip install schemdraw;  python3 hardware/schematics/draw.py
"""
import os
import schemdraw
import schemdraw.elements as elm

HERE = os.path.dirname(os.path.abspath(__file__))
schemdraw.config(fontsize=11, lw=1.2)


def duty_cycle_divider():
    with schemdraw.Drawing(file=os.path.join(HERE, 'duty-cycle-divider.svg'), show=False) as d:
        d += elm.Label().at((-1, 9.4)).label('Duty-cycle divider:  V_P = 10 V · V_num / V_den', 'right', fontsize=14, halign='left')

        # U2: inverter, -V_den
        d += elm.Dot(open=True).at((-1, 7)).label('V_den', 'left')
        d += elm.Resistor().at((-1, 7)).to((1.8, 7)).label('10k')
        d += elm.Dot().at((1.8, 7))
        d += elm.Line().at((1.8, 7)).to((2.5, 7))
        d += (u2 := elm.Opamp(leads=True).right().anchor('in1').at((2.5, 7)).label('U2', 'center', ofst=(-0.3, 0)))
        d += elm.Line().at(u2.in2).to((2.1, u2.in2[1]))
        d += elm.Ground().at((2.1, u2.in2[1]))
        d += elm.Line().at((1.8, 7)).to((1.8, 8.3))
        d += elm.Resistor().at((1.8, 8.3)).to((6.4, 8.3)).label('10k')
        d += elm.Line().at((6.4, 8.3)).to((6.4, u2.out[1]))
        d += elm.Line().at(u2.out).to((7.4, u2.out[1]))
        d += elm.Dot().at((6.4, u2.out[1])).label('−V_den', 'bottom')

        # SW1: connects -V_den to R2 while PWM is high. Open contributes no
        # current into the virtual-ground node, same as switching to 0 V.
        y1 = u2.out[1]
        d += elm.Switch().at((7.4, y1)).to((9.4, y1)).label('SW1', 'bottom')

        # U1: integrator
        d += (u1 := elm.Opamp(leads=True).right().anchor('in1').at((10.4, 3.62)).label('U1', 'center', ofst=(-0.3, 0)))
        d += elm.Resistor().at((9.4, y1)).to((9.4, 3.62)).label('R2\n100k', 'right')
        d += elm.Dot().at((9.4, 3.62))
        d += elm.Line().at((9.4, 3.62)).to(u1.in1)
        d += elm.Dot(open=True).at((5.4, 3.62)).label('V_num', 'left')
        d += elm.Resistor().at((5.4, 3.62)).to((9.4, 3.62)).label('R1 100k')
        d += elm.Line().at(u1.in2).to((10.1, u1.in2[1]))
        d += elm.Ground().at((10.1, u1.in2[1]))
        d += elm.Line().at((9.4, 3.62)).to((9.4, 0.4))
        d += elm.Capacitor().at((9.4, 0.4)).to((14.3, 0.4)).label('C1 10n', 'bottom')
        d += elm.Line().at((14.3, 0.4)).to((14.3, u1.out[1]))
        d += elm.Line().at(u1.out).to((14.3, u1.out[1]))
        d += elm.Dot().at((14.3, u1.out[1]))

        # U3: comparator, PWM high while triangle > integrator
        d += (u3 := elm.Opamp(leads=True).right().anchor('in1').at((15.5, 3.62)).label('U3\nLM311', 'center', ofst=(-0.3, 0)))
        d += elm.Line().at((14.3, u1.out[1])).to((14.3, 3.62))
        d += elm.Line().at((14.3, 3.62)).to(u3.in1)
        d += elm.Line().at(u3.in2).to((15.1, u3.in2[1]))
        d += elm.Line().at((15.1, u3.in2[1])).to((15.1, 1.6))
        d += elm.SourceSin().at((15.1, 1.6)).down()
        d += elm.Ground()
        d += elm.Label().at((15.7, 0.1)).label('triangle\n10 kHz, 0–10 V', 'right', halign='left')
        d += elm.Line().at(u3.out).to((19.5, u3.out[1]))
        d += elm.Dot().at((19.5, u3.out[1])).label('PWM δ', 'top')

        # PWM drives both switches
        d += elm.Line(ls='--').at((19.5, u3.out[1])).to((19.5, 7.4))
        d += elm.Line(ls='--').at((19.5, 7.4)).to((8.4, 7.4))
        d += elm.Line(ls='--').at((8.4, 7.4)).to((8.4, y1 + 0.35))
        d += elm.Line(ls='--').at((19.5, u3.out[1])).to((19.5, 1.0))
        d += elm.Line(ls='--').at((19.5, 1.0)).to((22.2, 1.0))
        d += elm.Line(ls='--').at((22.2, 1.0)).to((22.2, u3.out[1] - 0.2))

        # SW2: 10 V or 0 V, same PWM, then 2-pole RC filter and follower
        yo = u3.out[1]
        d += (sw2 := elm.SwitchSpdt2(action='close').left().anchor('a').at((22.6, yo)).label('SW2', 'top', ofst=0.9))
        hi, lo = (sw2.b, sw2.c) if sw2.b[1] > sw2.c[1] else (sw2.c, sw2.b)
        d += elm.Line().at(hi).to((hi[0] - 0.7, hi[1]))
        d += elm.Line().at((hi[0] - 0.7, hi[1])).to((hi[0] - 0.7, yo + 1.6))
        d += elm.Dot(open=True).at((hi[0] - 0.7, yo + 1.6)).label('10 V ref', 'top')
        d += elm.Line().at(lo).to((lo[0] - 0.7, lo[1]))
        d += elm.Ground().at((lo[0] - 0.7, lo[1]))
        d += elm.Resistor().at((22.6, yo)).to((25.6, yo)).label('10k')
        d += elm.Dot().at((25.6, yo))
        d += elm.Capacitor().at((25.6, yo)).to((25.6, yo - 1.8)).label('1µ', 'right')
        d += elm.Ground().at((25.6, yo - 1.8))
        d += elm.Resistor().at((25.6, yo)).to((28.6, yo)).label('10k')
        d += elm.Dot().at((28.6, yo))
        d += elm.Capacitor().at((28.6, yo)).to((28.6, yo - 1.8)).label('1µ', 'right')
        d += elm.Ground().at((28.6, yo - 1.8))
        d += (u4 := elm.Opamp(leads=True).right().anchor('in2').at((29.3, yo)).label('U4', 'center', ofst=(-0.3, 0)))
        d += elm.Line().at((28.6, yo)).to(u4.in2)
        d += elm.Line().at(u4.in1).to((28.9, u4.in1[1]))
        d += elm.Line().at((28.9, u4.in1[1])).to((28.9, u4.in1[1] + 0.9))
        d += elm.Line().at((28.9, u4.in1[1] + 0.9)).to((33.2, u4.in1[1] + 0.9))
        d += elm.Line().at((33.2, u4.in1[1] + 0.9)).to((33.2, u4.out[1]))
        d += elm.Line().at(u4.out).to((33.8, u4.out[1]))
        d += elm.Dot(open=True).at((33.8, u4.out[1])).label('V_P', 'right')

        d += elm.Label().at((-1, -3.4)).label(
            'How it works: SW1 feeds −V_den into the integrator for a fraction δ of each cycle. The integrator only stops moving when its '
            'average input is zero:\nV_num − δ·V_den = 0, so δ = V_num / V_den. SW2 switches 10 V with the same PWM, so after the filter '
            'V_P = δ · 10 V = 10 V · V_num / V_den.\nThe triangle\'s exact shape and amplitude don\'t matter (the loop corrects for them); '
            'only switch timing and the 10 V reference do.\nParts: TL074 (U1, U2, U4 + the triangle oscillator), LM311 (U3), DG403 (SW1, SW2).',
            'right', fontsize=10, halign='left')


def rheostat_divider():
    with schemdraw.Drawing(file=os.path.join(HERE, 'rheostat-divider.svg'), show=False) as d:
        d += elm.Label().at((-1, 9.2)).label(
            'Pot divider ("the knob is the divider"):  V_P = 10 V · (D − d) / (40 − n)', 'right', fontsize=14, halign='left')

        # P1: danger played, a plain voltage divider: V_d = 0.25 V per card
        d += elm.Dot(open=True).at((-1, 7.5)).label('10 V ref', 'left')
        d += elm.Line().at((-1, 7.5)).to((0, 7.5))
        d += (p1 := elm.Potentiometer().at((0, 7.5)).down())
        d += elm.Ground()
        d += elm.Label().at((-0.6, 6.4)).label('P1  danger played d\n(dial 0–40)', 'left', halign='right')
        d += elm.Line().at(p1.tap).to((1.6, p1.tap[1])).label('V_d', 'top')

        # U1: difference amp, V_num = V_D - V_d
        y = p1.tap[1]
        d += elm.Resistor().at((1.6, y)).to((4.6, y)).label('10k')
        d += elm.Dot().at((4.6, y))
        d += (u1 := elm.Opamp(leads=True).right().anchor('in1').at((5.2, y)).label('U1', 'center', ofst=(-0.3, 0)))
        d += elm.Line().at((4.6, y)).to(u1.in1)
        d += elm.Line().at((4.6, y)).to((4.6, y + 1.4))
        d += elm.Resistor().at((4.6, y + 1.4)).to((u1.out[0] + 0.4, y + 1.4)).label('10k')
        d += elm.Line().at((u1.out[0] + 0.4, y + 1.4)).to((u1.out[0] + 0.4, u1.out[1]))
        d += elm.Line().at(u1.out).to((u1.out[0] + 0.4, u1.out[1]))
        yp = u1.in2[1]
        d += elm.Line().at(u1.in2).to((4.4, yp))
        d += elm.Dot().at((4.4, yp))
        d += elm.Resistor().at((4.4, yp)).to((4.4, yp - 2.6)).label('10k', 'right')
        d += elm.Ground().at((4.4, yp - 2.6))
        d += elm.Resistor().at((1.4, yp)).to((4.4, yp)).label('10k', 'bottom')
        d += elm.Line().at((1.4, yp)).to((1.4, yp - 1.6))
        d += elm.Dot(open=True).at((1.4, yp - 1.6)).label('V_D from detectors\n(0.25 V per card)', 'bottom')
        xn = u1.out[0] + 0.4
        d += elm.Dot().at((xn, u1.out[1])).label('V_num', 'bottom')

        # U2: inverting amp; its input resistor is the cards-played pot as a rheostat
        yo = u1.out[1]
        d += elm.Potentiometer().at((xn, yo)).to((xn + 3.4, yo)).label(
            'P2  cards played n\n(rheostat: R = R₀·(40 − n)/40)', 'top', ofst=0.35)
        d += elm.Dot().at((xn + 3.4, yo))
        d += (u2 := elm.Opamp(leads=True).right().anchor('in1').at((xn + 4.0, yo)).label('U2', 'center', ofst=(-0.3, 0)))
        d += elm.Line().at((xn + 3.4, yo)).to(u2.in1)
        d += elm.Line().at((xn + 3.4, yo)).to((xn + 3.4, yo + 2.2))
        d += elm.Resistor().at((xn + 3.4, yo + 2.2)).to((u2.out[0] + 0.4, yo + 2.2)).label('R_f = R₀ (P2\'s full track)')
        d += elm.Line().at((u2.out[0] + 0.4, yo + 2.2)).to((u2.out[0] + 0.4, u2.out[1]))
        d += elm.Line().at(u2.out).to((u2.out[0] + 0.4, u2.out[1]))
        d += elm.Line().at(u2.in2).to((xn + 3.7, u2.in2[1]))
        d += elm.Line().at((xn + 3.7, u2.in2[1])).to((xn + 3.7, u2.in2[1] - 0.6))
        d += elm.Ground().at((xn + 3.7, u2.in2[1] - 0.6))
        x2 = u2.out[0] + 0.4
        d += elm.Dot().at((x2, u2.out[1])).label('−V_P', 'bottom')

        # U3: unity inverter
        yo2 = u2.out[1]
        d += elm.Resistor().at((x2, yo2)).to((x2 + 2.6, yo2)).label('10k')
        d += elm.Dot().at((x2 + 2.6, yo2))
        d += (u3 := elm.Opamp(leads=True).right().anchor('in1').at((x2 + 3.2, yo2)).label('U3', 'center', ofst=(-0.3, 0)))
        d += elm.Line().at((x2 + 2.6, yo2)).to(u3.in1)
        d += elm.Line().at((x2 + 2.6, yo2)).to((x2 + 2.6, yo2 + 1.4))
        d += elm.Resistor().at((x2 + 2.6, yo2 + 1.4)).to((u3.out[0] + 0.4, yo2 + 1.4)).label('10k')
        d += elm.Line().at((u3.out[0] + 0.4, yo2 + 1.4)).to((u3.out[0] + 0.4, u3.out[1]))
        d += elm.Line().at(u3.out).to((u3.out[0] + 0.8, u3.out[1]))
        d += elm.Line().at(u3.in2).to((x2 + 2.9, u3.in2[1]))
        d += elm.Line().at((x2 + 2.9, u3.in2[1])).to((x2 + 2.9, u3.in2[1] - 0.6))
        d += elm.Ground().at((x2 + 2.9, u3.in2[1] - 0.6))
        d += elm.Dot(open=True).at((u3.out[0] + 0.8, u3.out[1])).label('V_P', 'right')

        d += elm.Label().at((-1, -1.6)).label(
            'An inverting amplifier\'s gain is R_f / R_in. Make R_in the "cards played" pot, wired so its resistance is proportional to the\n'
            'cards LEFT, and the amplifier divides by cards left. With R_f equal to the full track R₀:\n'
            '      V_P = V_num · 40/(40 − n) = 10 V · (D − d)/(40 − n).\n'
            'V_P goes to the IN-13 driver. One quad op-amp (TL074) does all of it. Accuracy is the pots\': their linearity and how precisely you set them (about ±1 card).\n'
            'A mechanical stop at n = 39 keeps R_in from reaching zero.',
            'right', fontsize=10, halign='left')


if __name__ == '__main__':
    duty_cycle_divider()
    rheostat_divider()
    print('wrote', HERE)
