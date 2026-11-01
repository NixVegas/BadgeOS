/* song.h: the demo's tune: 140 BPM, 4 rows/beat, 8 patterns, loops forever.
 * Note numbers are semitones above A1(55Hz)+24, i.e. 24 == A3. 0 == rest.
 */
#ifndef BADGE_SONG_H
#define BADGE_SONG_H
#include "synth.h"

#define A3 24
#define C4 27
#define D4 29
#define E4 31
#define F4 32
#define G4 34
#define A4 36
#define C5 39
#define D5 41
#define E5 43
#define G5 46
#define A5 48
#define A2 12
#define C3 15
#define D3 17
#define E3 19
#define F3 20
#define G3 22
#define KI 40   /* drum: kick  */
#define SN 60   /* drum: snare */
#define HH 80   /* drum: hat   */

/* [pattern][channel][row] : bass, lead, arp, pad, drums */
static const uint8_t PATS[8][NCHAN][ROWS] = {
/* 0: intro: pad + hats only */
{{0},
 {0},
 {0},
 {A3,0,0,0, 0,0,0,0, E4,0,0,0, 0,0,0,0},
 {0,0,HH,0, 0,0,HH,0, 0,0,HH,0, 0,0,HH,0}},
/* 1: bass enters */
{{A2,0,0,0, A2,0,0,0, G3,0,0,0, G3,0,0,0},
 {0},
 {A4,0,E5,0, A4,0,C5,0, G4,0,D5,0, G4,0,A4,0},
 {A3,0,0,0, 0,0,0,0, G3,0,0,0, 0,0,0,0},
 {KI,0,HH,0, 0,0,HH,SN, KI,0,HH,0, 0,0,HH,SN}},
/* 2: lead A */
{{A2,0,0,A2, 0,0,A2,0, F3,0,0,F3, 0,0,F3,0},
 {A4,0,C5,0, E5,0,C5,0, D5,0,F4,0, A4,0,0,0},
 {A4,E5,A4,E5, A4,E5,A4,E5, F4,C5,F4,C5, F4,C5,F4,C5},
 {A3,0,0,0, 0,0,0,0, F3,0,0,0, 0,0,0,0},
 {KI,0,HH,0, 0,0,HH,SN, KI,0,HH,0, KI,0,HH,SN}},
/* 3: lead B */
{{C3,0,0,C3, 0,0,C3,0, G3,0,0,G3, 0,0,G3,0},
 {E5,0,D5,0, C5,0,A4,0, G4,0,A4,0, C5,0,D5,0},
 {C5,G5,C5,G5, C5,G5,C5,G5, G4,D5,G4,D5, G4,D5,G4,D5},
 {C4,0,0,0, 0,0,0,0, G3,0,0,0, 0,0,0,0},
 {KI,0,HH,0, 0,0,HH,SN, KI,0,HH,KI, 0,0,HH,SN}},
/* 4: break: arp only */
{{0},
 {0},
 {A4,C5,E5,A5, E5,C5,A4,E4, G4,C5,D5,G5, D5,C5,G4,D4},
 {0},
 {0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,SN,SN}},
/* 5: drop */
{{A2,A2,0,A2, 0,A2,0,A2, F3,F3,0,F3, 0,F3,0,F3},
 {A5,0,0,G5, 0,0,E5,0, 0,0,C5,0, D5,0,E5,0},
 {A4,E5,A4,E5, A4,E5,A4,E5, F4,C5,F4,C5, F4,C5,F4,C5},
 {A3,0,0,0, 0,0,0,0, F3,0,0,0, 0,0,0,0},
 {KI,0,HH,0, KI,0,HH,SN, KI,0,HH,0, KI,0,HH,SN}},
/* 6: lift */
{{D3,0,0,D3, 0,0,D3,0, E3,0,0,E3, 0,0,E3,0},
 {D5,0,E5,0, G5,0,E5,0, A5,0,G5,0, E5,0,D5,0},
 {D4,A4,D5,A4, D4,A4,D5,A4, E4,C5,E5,C5, E4,C5,E5,C5},
 {D4,0,0,0, 0,0,0,0, E4,0,0,0, 0,0,0,0},
 {KI,0,HH,0, KI,0,HH,SN, KI,0,HH,KI, KI,SN,SN,SN}},
/* 7: outro / turnaround */
{{A2,0,0,0, 0,0,0,0, E3,0,0,0, 0,0,0,0},
 {A4,0,0,0, E4,0,0,0, C5,0,0,0, 0,0,0,0},
 {A4,E5,A4,E5, 0,0,0,0, A4,C5,E5,A5, 0,0,0,0},
 {A3,0,0,0, 0,0,0,0, A3,0,0,0, 0,0,0,0},
 {KI,0,HH,0, 0,0,HH,0, KI,0,HH,0, 0,SN,SN,SN}},
};

static const uint8_t ORDER[] = { 0,1,2,3,2,3,4,5,5,6,3,7 };

static const struct song SONG = {
	.bpm = 140, .rows_per_beat = 4,
	.npat = (int)(sizeof(ORDER) / sizeof(ORDER[0])),
	.order = ORDER, .pat = PATS,
};

#endif
