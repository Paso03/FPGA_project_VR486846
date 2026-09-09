# FPGA Heart Rate Monitor

## Descrizione del progetto

Il progetto consiste nella realizzazione di un **Heart Rate Monitor su FPGA**, sviluppato per la scheda **PYNQ-Z1**.

L'obiettivo è realizzare un sistema in grado di:

- generare un segnale ECG sintetico;
- conoscere i battiti realmente presenti nel segnale generato;
- trasferire i campioni ECG alla FPGA;
- rilevare i battiti tramite un modulo hardware realizzato in **Verilog HDL**;
- calcolare i principali parametri della frequenza cardiaca;
- leggere i risultati dalla FPGA tramite un'interfaccia **AXI-Lite**;
- confrontare i risultati ottenuti dall'hardware con i valori attesi.

Il progetto utilizza quindi sia una parte **software**, sviluppata in Python, sia una parte **hardware**, sviluppata in Verilog e integrata tramite **Vivado**.

---

# Architettura del sistema

L'architettura complessiva del progetto può essere rappresentata come segue:

```text
                       PYTHON
              +----------------------+
              | signal_generator.py  |
              |                      |
              | Generazione ECG       |
              | Ground Truth          |
              +----------+-----------+
                         |
                         | Campioni ECG
                         v
              +----------------------+
              |    heart_rate.py      |
              |                      |
              | Verifica software    |
              | Interfaccia FPGA      |
              +----------+-----------+
                         |
                         | AXI-Lite
                         v
        +--------------------------------------+
        |               PYNQ-Z1                |
        |                                      |
        |  +-------------------------------+   |
        |  | Zynq Processing System        |   |
        |  +---------------+---------------+   |
        |                  |                    |
        |                AXI-Lite               |
        |                  |                    |
        |  +---------------v---------------+   |
        |  |       heart_rate_ip_0         |   |
        |  |                               |   |
        |  |   Heart Rate Monitor          |   |
        |  |                               |   |
        |  |   - rilevamento battiti       |   |
        |  |   - intervallo RR             |   |
        |  |   - BPM medio                 |   |
        |  |   - BPM minimo                |   |
        |  |   - BPM massimo               |   |
        |  |   - conteggio campioni        |   |
        |  +-------------------------------+   |
        +--------------------------------------+
```

Il segnale ECG viene generato in Python e successivamente utilizzato come ingresso del sistema hardware.

---

# Piattaforma hardware

Il progetto è stato sviluppato per la scheda:

**PYNQ-Z1**

basata sul dispositivo **Xilinx Zynq-7020**.

Il sistema Vivado comprende:

- Zynq Processing System;
- IP personalizzato Heart Rate Monitor;
- interfaccia AXI-Lite;
- Block Design;
- collegamento tra Processing System e IP personalizzato.

I file hardware principali utilizzati sulla PYNQ sono:

```text
system.bit
system.hwh
system.tcl
```

### `system.bit`

È il **bitstream** utilizzato per configurare la logica programmabile della FPGA.

### `system.hwh`

Contiene le informazioni relative all'hardware del sistema e permette all'ambiente PYNQ di riconoscere la struttura del progetto e gli IP presenti.

### `system.tcl`

Contiene la descrizione Tcl del Block Design realizzato in Vivado.

---

# Generazione del segnale ECG

Il file:

```text
signal_generator.py
```

si occupa della generazione del segnale ECG sintetico.

Il segnale non proviene da un sensore reale, ma viene costruito matematicamente in Python in modo da avere caratteristiche simili a un ECG.

Per ogni battito vengono generate le principali onde:

- P;
- Q;
- R;
- S;
- T.

Inoltre, per rendere il segnale più realistico, sono state introdotte diverse variabilità:

- variabilità della frequenza cardiaca;
- variazione casuale dell'intervallo tra battiti;
- variazione dell'ampiezza delle onde;
- variazione della larghezza delle onde;
- baseline wander;
- rumore gaussiano.

La configurazione predefinita è:

```text
Frequenza di campionamento : 250 Hz
Frequenza cardiaca nominale: 72 BPM
Durata                      : 120 s
Numero di campioni         : 30000
Soglia di rilevamento      : 30000
```

Il generatore restituisce:

- vettore temporale;
- segnale ECG;
- posizione dei picchi R generati;
- intervallo nominale tra i battiti.

Le posizioni dei picchi R rappresentano la **ground truth** del segnale.

Questo permette di confrontare i risultati prodotti dal rilevatore con quelli realmente presenti nel segnale generato.

È importante sottolineare che il valore di BPM utilizzato durante la generazione del segnale **non viene fornito alla FPGA**.

La FPGA riceve solamente:

- campioni ECG;
- frequenza di campionamento;
- soglia di rilevamento.

Il valore di BPM viene quindi calcolato dall'hardware a partire dagli intervalli tra i battiti rilevati.

---

# Algoritmo di rilevamento dei battiti

Il rilevatore hardware è implementato nel file:

```text
heart_rate_ip/heart_rate_monitor.v
```

L'algoritmo utilizzato è basato sul superamento di una soglia.

Un battito viene rilevato quando il segnale passa da un valore inferiore alla soglia a un valore superiore o uguale alla soglia.

In maniera semplificata:

```text
Segnale < soglia
       |
       | attraversamento della soglia
       v
Segnale >= soglia
       |
       v
Battito rilevato
```

Per evitare di rilevare più volte lo stesso battito viene utilizzato un **periodo refrattario**.

Nel progetto il periodo refrattario è impostato a:

```text
50 campioni
```

Con una frequenza di campionamento di 250 Hz:

```text
50 / 250 = 0,2 s
```

Durante questo intervallo non vengono accettati nuovi battiti.

---

# Calcolo degli intervalli RR

Quando vengono rilevati due battiti consecutivi, viene calcolato il numero di campioni che li separa.

Questo intervallo rappresenta l'intervallo **RR**.

Indicando con:

```text
Fs = frequenza di campionamento
N  = intervallo RR espresso in campioni
```

la frequenza cardiaca istantanea viene calcolata mediante:

```text
BPM = (60 × Fs) / N
```

Il modulo hardware calcola inoltre:

- numero di battiti rilevati;
- ultimo intervallo RR;
- intervallo RR medio;
- BPM medio;
- BPM minimo;
- BPM massimo;
- numero di campioni elaborati.

Le divisioni vengono effettuate con aritmetica intera, quindi i valori BPM restituiti dall'FPGA sono interi.

---

# IP personalizzato

La cartella:

```text
heart_rate_ip/
```

contiene i file relativi all'implementazione hardware del progetto.

I principali file sono:

```text
heart_rate_monitor.v
```

Modulo Verilog principale contenente l'algoritmo di rilevamento e calcolo della frequenza cardiaca.

```text
tb_heart_rate_monitor.v
```

Testbench utilizzato per verificare il comportamento del modulo Verilog.

```text
heart_rate_ip
```

File relativi al progetto/IP personalizzato sviluppato in Vivado.

```text
heart_rate_ip_AXI
```

Parte relativa all'interfaccia AXI-Lite utilizzata per collegare il modulo alla Processing System del dispositivo Zynq.

---

# Interfaccia AXI-Lite

Il modulo Heart Rate Monitor viene controllato tramite registri **memory-mapped** attraverso un'interfaccia AXI-Lite.

La mappa dei registri utilizzata è la seguente:

| Indirizzo | Registro | Descrizione |
|----------:|----------|-------------|
| `0x00` | CONTROL | Comandi di controllo |
| `0x04` | SAMPLE | Campione ECG |
| `0x08` | STATUS | Stato del modulo |
| `0x0C` | BPM | BPM medio |
| `0x10` | BEAT_COUNT | Numero di battiti rilevati |
| `0x14` | LAST_INTERVAL | Ultimo intervallo RR |
| `0x18` | AVG_INTERVAL | Intervallo RR medio |
| `0x1C` | MIN_BPM | BPM minimo |
| `0x20` | MAX_BPM | BPM massimo |
| `0x24` | SAMPLE_COUNT | Numero di campioni elaborati |
| `0x28` | THRESHOLD | Soglia di rilevamento |
| `0x2C` | SAMPLE_RATE | Frequenza di campionamento |

## Registro CONTROL

Il registro `CONTROL` contiene i seguenti bit:

| Bit | Nome | Descrizione |
|----:|------|-------------|
| 0 | `SAMPLE_VALID` | Indica la presenza di un nuovo campione |
| 1 | `CLEAR` | Azzera lo stato interno del modulo |
| 2 | `START` | Avvia l'elaborazione |
| 3 | `STOP` | Arresta l'elaborazione |

## Registro STATUS

Il registro `STATUS` contiene:

| Bit | Nome | Descrizione |
|----:|------|-------------|
| 0 | `BUSY` | Elaborazione attiva |
| 1 | `BEAT_DETECTED` | Indicazione di rilevamento di un battito |
| 2 | `BPM_VALID` | Risultato BPM disponibile |
| 3 | `PROCESSING_DONE` | Elaborazione completata |

---

# Programma Python

Il programma principale è:

```text
heart_rate.py
```

Il programma può essere eseguito in due modalità:

```text
simulation
hardware
```

---

# Modalità simulation

La modalità `simulation` permette di testare l'intero algoritmo senza utilizzare fisicamente la PYNQ-Z1.

Viene eseguita la seguente sequenza:

```text
Generazione ECG
      ↓
Ground Truth
      ↓
Software Heart Rate Monitor
      ↓
Rilevamento battiti
      ↓
Confronto con Ground Truth
      ↓
PASS / FAIL
```

Per eseguire la simulazione:

```bash
python heart_rate.py --mode simulation
```

Per visualizzare anche il segnale:

```bash
python heart_rate.py --mode simulation --plot
```

È inoltre possibile visualizzare solamente una parte del segnale, ad esempio i primi 10 secondi:

```bash
python heart_rate.py --mode simulation --plot --plot-seconds 10
```

---

# Modalità hardware

La modalità `hardware` è destinata all'esecuzione sulla PYNQ-Z1.

Nella cartella del progetto devono essere presenti:

```text
heart_rate.py
signal_generator.py
system.bit
system.hwh
```

Il programma cerca automaticamente `system.bit` nella stessa cartella di `heart_rate.py`.

La sequenza di funzionamento è:

```text
Generazione ECG
      ↓
Caricamento del bitstream
      ↓
Configurazione dell'IP
      ↓
Avvio elaborazione
      ↓
Invio dei campioni ECG tramite AXI-Lite
      ↓
Arresto elaborazione
      ↓
Lettura dei registri
      ↓
Confronto dei risultati
```

Per effettuare un test hardware breve:

```bash
python heart_rate.py --mode hardware --duration 10
```

Per eseguire il test completo:

```bash
python heart_rate.py --mode hardware
```

---

# Verifica RTL

Il modulo Verilog è stato verificato tramite un testbench dedicato:

```text
heart_rate_ip/tb_heart_rate_monitor.v
```

Il testbench permette di verificare il comportamento del rilevatore utilizzando intervalli tra battiti differenti.

Sono stati verificati:

- rilevamento dei battiti;
- periodo refrattario;
- conteggio dei battiti;
- intervallo tra battiti;
- intervallo medio;
- BPM medio;
- BPM minimo;
- BPM massimo;
- conteggio dei campioni;
- stato di elaborazione.

---

# Verifica software

Prima della verifica sulla FPGA è stata eseguita una verifica offline sul PC.

In questa fase il segnale ECG viene generato in Python e viene elaborato da una versione software dell'algoritmo che replica il comportamento del modulo Verilog.

Per il test sono stati utilizzati:

```text
Durata                  : 120,00 s
Frequenza campionamento : 250 Hz
Campioni generati       : 30000
BPM nominale            : 72
Intervallo nominale     : 208 campioni
Deviazione standard rumore: 100
```

La ground truth del segnale generato ha prodotto:

```text
Battiti generati       : 144
BPM medio              : 72,54
BPM minimo             : 66,67
BPM massimo            : 78,53
Intervallo medio       : 207,17 campioni
```

Il rilevatore software ha prodotto:

```text
Battiti rilevati       : 144
BPM medio              : 72
BPM minimo             : 66
BPM massimo            : 78
Intervallo medio       : 207 campioni
Ultimo intervallo      : 220 campioni
Campioni elaborati     : 30000
Durata                 : 120,00 s
```

Il confronto ha fornito:

```text
Battiti generati       : 144
Battiti rilevati       : 144
Battiti corrispondenti : 144

Errore medio posizione : 6,08 campioni
Errore massimo         : 7 campioni
Errore medio BPM       : 0,74 %
```

Risultato:

```text
STATUS: PASS
```

A 250 Hz ogni campione corrisponde a:

```text
1 / 250 = 4 ms
```

Pertanto un errore medio di 6,08 campioni corrisponde a circa:

```text
6,08 × 4 ms ≈ 24 ms
```

La differenza di posizione è dovuta al fatto che la ground truth identifica il centro del picco R generato, mentre il rilevatore basato sulla soglia individua il primo campione che supera la soglia.

---

# Flusso di sviluppo Vivado

La parte hardware è stata sviluppata utilizzando **Vivado 2019.1**.

Il flusso seguito è:

```text
Modulo Verilog
      ↓
Testbench
      ↓
Verifica RTL
      ↓
Creazione IP personalizzato
      ↓
Interfaccia AXI-Lite
      ↓
Block Design
      ↓
Zynq Processing System
      ↓
Synthesis
      ↓
Implementation
      ↓
Bitstream
```

Il risultato finale del progetto Vivado è rappresentato dai file:

```text
system.bit
system.hwh
system.tcl
```

# Requisiti software

Per la parte Python sono necessari:

- Python 3;
- NumPy;
- Matplotlib.

Per la modalità `hardware` è inoltre necessario l'ambiente **PYNQ** sulla scheda PYNQ-Z1.

---


# Esecuzione

## Verifica offline

```bash
python heart_rate.py --mode simulation
```

## Verifica offline con grafico

```bash
python heart_rate.py --mode simulation --plot
```

## Test hardware breve

```bash
python heart_rate.py --mode hardware --duration 10
```

## Test hardware completo

```bash
python heart_rate.py --mode hardware
```

# Possibili sviluppi futuri

Il progetto può essere ulteriormente sviluppato introducendo:

- acquisizione di un ECG reale tramite sensore;
- filtri digitali per la riduzione del rumore;
- algoritmi più avanzati per il rilevamento dei picchi R;
- elaborazione in tempo reale;
- visualizzazione grafica dell'ECG;
- utilizzo di AXI DMA al posto dell'invio campione per campione tramite AXI-Lite;
- utilizzo di dataset ECG reali per una verifica più approfondita.
