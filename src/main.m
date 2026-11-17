// PadProbe — diagnóstico de controles Bluetooth via BTstack (iOS 8, jailbreak)
//
// Procura controles, conecta como host HID (L2CAP PSM 0x11/0x13) e mostra os
// relatórios (reports) que cada botão gera. Serve para descobrir se o controle
// conversa com o BTstack e qual o formato dos dados, antes de integrar no emulador.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include "btstack.h"
#include "hci_cmds.h"
#include "run_loop.h"
#include "utils.h"

#pragma mark - Estado global (o BTstack chama callbacks em C)

@class PPViewController;
static __weak PPViewController *gVC;

typedef struct {
    bd_addr_t addr;
    uint8_t pageScanRepMode;
    uint16_t clockOffset;
    uint32_t cod;
    char name[64];
    int nameRequested;
} pp_device_t;

#define PP_MAX_DEVICES 20
static pp_device_t gDevices[PP_MAX_DEVICES];
static int gDeviceCount = 0;
static int gInquiryActive = 0;
static int gNameRequestPending = 0;

static bd_addr_t gTargetAddr;
static uint16_t gControlCid = 0;
static uint16_t gInterruptCid = 0;

static uint8_t gBaseline[64];
static int gBaselineLen = 0;
static uint8_t gLastReport[64];
static int gLastLen = 0;

static void pp_log(NSString *text);
static void pp_devices_changed(void);
static void pp_report(const uint8_t *data, int len);
static void pp_status(NSString *text);

static NSString *pp_addr_string(bd_addr_t a) {
    return [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X", a[0], a[1], a[2], a[3], a[4], a[5]];
}

static NSString *pp_cod_string(uint32_t cod) {
    uint32_t major = (cod >> 8) & 0x1F;
    uint32_t minor = (cod >> 2) & 0x3F;
    if (major == 0x05) {
        // Periférico: bits 2-5 do minor = tipo (joystick/gamepad...)
        switch (minor & 0x0F) {
            case 0x01: return @"joystick";
            case 0x02: return @"gamepad";
            default: break;
        }
        if (minor & 0x10) return @"teclado";
        if (minor & 0x20) return @"mouse";
        return @"periférico";
    }
    if (major == 0x01) return @"computador";
    if (major == 0x02) return @"telefone";
    if (major == 0x04) return @"áudio";
    return [NSString stringWithFormat:@"COD 0x%06X", cod];
}

static int pp_find_device(bd_addr_t addr) {
    for (int i = 0; i < gDeviceCount; i++) {
        if (BD_ADDR_CMP(gDevices[i].addr, addr) == 0) return i;
    }
    return -1;
}

static int pp_add_device(bd_addr_t addr, uint8_t psrm, uint16_t clock, uint32_t cod) {
    int idx = pp_find_device(addr);
    if (idx < 0) {
        if (gDeviceCount >= PP_MAX_DEVICES) return -1;
        idx = gDeviceCount++;
        memset(&gDevices[idx], 0, sizeof(pp_device_t));
        BD_ADDR_COPY(gDevices[idx].addr, addr);
        pp_log([NSString stringWithFormat:@"Encontrado %@ (%@)", pp_addr_string(addr), pp_cod_string(cod)]);
    }
    gDevices[idx].pageScanRepMode = psrm;
    gDevices[idx].clockOffset = clock;
    gDevices[idx].cod = cod;
    pp_devices_changed();
    return idx;
}

static void pp_request_next_name(void) {
    if (gNameRequestPending || gInquiryActive) return;
    for (int i = 0; i < gDeviceCount; i++) {
        if (!gDevices[i].nameRequested && gDevices[i].name[0] == 0) {
            gDevices[i].nameRequested = 1;
            gNameRequestPending = 1;
            bt_send_cmd(&hci_remote_name_request, gDevices[i].addr, gDevices[i].pageScanRepMode, 0,
                        gDevices[i].clockOffset | 0x8000);
            return;
        }
    }
}

static void pp_parse_eir_name(int idx, const uint8_t *eir, int len) {
    int pos = 0;
    while (pos < len) {
        int fieldLen = eir[pos];
        if (fieldLen == 0 || pos + 1 + fieldLen > len) break;
        int type = eir[pos + 1];
        if (type == 0x08 || type == 0x09) {
            int n = MIN(fieldLen - 1, 63);
            memcpy(gDevices[idx].name, &eir[pos + 2], n);
            gDevices[idx].name[n] = 0;
            pp_devices_changed();
            return;
        }
        pos += fieldLen + 1;
    }
}

#pragma mark - Packet handler

static void pp_packet_handler(uint8_t packet_type, uint16_t channel, uint8_t *packet, uint16_t size) {
    bd_addr_t addr;

    if (packet_type == L2CAP_DATA_PACKET) {
        if (channel == gInterruptCid || channel == gControlCid) {
            pp_report(packet, size);
        }
        return;
    }
    if (packet_type != HCI_EVENT_PACKET) return;

    switch (packet[0]) {
        case BTSTACK_EVENT_STATE:
            if (packet[2] == HCI_STATE_WORKING) {
                pp_status(@"Bluetooth (BTstack) ligado");
                pp_log(@"BTstack pronto. Registrando serviços HID para aceitar reconexões.");
                bt_send_cmd(&l2cap_register_service, PSM_HID_CONTROL, 250);
                bt_send_cmd(&l2cap_register_service, PSM_HID_INTERRUPT, 250);
                bt_send_cmd(&hci_write_inquiry_mode, 0x02);  // resultados com nome (EIR), quando suportado
            } else {
                pp_log([NSString stringWithFormat:@"Estado do BTstack: %u", packet[2]]);
            }
            break;

        case BTSTACK_EVENT_POWERON_FAILED:
            pp_status(@"Falha ao ligar o Bluetooth");
            pp_log(@"BTSTACK_EVENT_POWERON_FAILED: desligue o Bluetooth do iOS em Ajustes e tente de novo.");
            break;

        case HCI_EVENT_INQUIRY_RESULT: {
            int num = packet[2];
            for (int i = 0; i < num; i++) {
                bt_flip_addr(addr, &packet[3 + i * 6]);
                uint8_t psrm = packet[3 + num * 6 + i];
                uint32_t cod = READ_BT_24(packet, 3 + num * 9 + i * 3);
                uint16_t clock = READ_BT_16(packet, 3 + num * 12 + i * 2);
                pp_add_device(addr, psrm, clock, cod);
            }
            break;
        }
        case HCI_EVENT_INQUIRY_RESULT_WITH_RSSI: {
            int num = packet[2];
            for (int i = 0; i < num; i++) {
                bt_flip_addr(addr, &packet[3 + i * 6]);
                uint8_t psrm = packet[3 + num * 6 + i];
                uint32_t cod = READ_BT_24(packet, 3 + num * 8 + i * 3);
                uint16_t clock = READ_BT_16(packet, 3 + num * 11 + i * 2);
                pp_add_device(addr, psrm, clock, cod);
            }
            break;
        }
        case HCI_EVENT_EXTENDED_INQUIRY_RESPONSE: {
            bt_flip_addr(addr, &packet[3]);
            int idx = pp_add_device(addr, packet[9], READ_BT_16(packet, 14), READ_BT_24(packet, 11));
            if (idx >= 0 && size > 17) pp_parse_eir_name(idx, &packet[17], size - 17);
            break;
        }
        case HCI_EVENT_INQUIRY_COMPLETE:
            gInquiryActive = 0;
            pp_status(@"Busca terminada");
            pp_log(@"Busca terminada. Pedindo nomes dos dispositivos...");
            pp_request_next_name();
            break;

        case HCI_EVENT_REMOTE_NAME_REQUEST_COMPLETE: {
            gNameRequestPending = 0;
            bt_flip_addr(addr, &packet[3]);
            int idx = pp_find_device(addr);
            if (idx >= 0 && packet[2] == 0) {
                strncpy(gDevices[idx].name, (const char *)&packet[9], 63);
                gDevices[idx].name[63] = 0;
                pp_devices_changed();
            }
            pp_request_next_name();
            break;
        }

        case HCI_EVENT_PIN_CODE_REQUEST: {
            // Pareamento antigo (sem SSP): tenta "0000" (o comando copia sempre 16 bytes)
            uint8_t pin[16] = {'0', '0', '0', '0'};
            bt_flip_addr(addr, &packet[2]);
            pp_log([NSString stringWithFormat:@"Pedido de PIN de %@, respondendo 0000", pp_addr_string(addr)]);
            bt_send_cmd(&hci_pin_code_request_reply, addr, 4, pin);
            break;
        }

        case HCI_EVENT_USER_CONFIRMATION_REQUEST:
            pp_log(@"Pareamento seguro (SSP): o BTstack aceita automaticamente.");
            break;

        case HCI_EVENT_AUTHENTICATION_COMPLETE_EVENT:
            pp_log([NSString stringWithFormat:@"Autenticação concluída, status 0x%02X", packet[2]]);
            break;

        case L2CAP_EVENT_INCOMING_CONNECTION: {
            bt_flip_addr(addr, &packet[2]);
            uint16_t psm = READ_BT_16(packet, 10);
            uint16_t localCid = READ_BT_16(packet, 12);
            pp_log([NSString stringWithFormat:@"Conexão de entrada de %@, PSM 0x%02X: aceitando", pp_addr_string(addr), psm]);
            bt_send_cmd(&l2cap_accept_connection, localCid);
            break;
        }

        case L2CAP_EVENT_CHANNEL_OPENED: {
            uint8_t status = packet[2];
            bt_flip_addr(addr, &packet[3]);
            uint16_t psm = READ_BT_16(packet, 11);
            uint16_t localCid = READ_BT_16(packet, 13);
            if (status) {
                pp_log([NSString stringWithFormat:@"Falha ao abrir canal PSM 0x%02X: status 0x%02X", psm, status]);
                pp_status(@"Falha na conexão");
                break;
            }
            pp_log([NSString stringWithFormat:@"Canal aberto: PSM 0x%02X, cid 0x%04X", psm, localCid]);
            if (psm == PSM_HID_CONTROL) {
                gControlCid = localCid;
                if (!gInterruptCid) {
                    bt_send_cmd(&l2cap_create_channel, addr, PSM_HID_INTERRUPT);
                }
            } else if (psm == PSM_HID_INTERRUPT) {
                gInterruptCid = localCid;
                gBaselineLen = 0;
                gLastLen = 0;
                pp_status(@"Conectado! Aperte os botões");
                pp_log(@"Controle conectado. Solte tudo, aperte \"Marcar repouso\" e depois um botão por vez.");
            }
            break;
        }

        case L2CAP_EVENT_CHANNEL_CLOSED: {
            uint16_t localCid = READ_BT_16(packet, 2);
            if (localCid == gInterruptCid) gInterruptCid = 0;
            if (localCid == gControlCid) gControlCid = 0;
            pp_log([NSString stringWithFormat:@"Canal 0x%04X fechado", localCid]);
            if (!gInterruptCid && !gControlCid) pp_status(@"Desconectado");
            break;
        }

        case HCI_EVENT_DISCONNECTION_COMPLETE:
            pp_log([NSString stringWithFormat:@"Desconectado (motivo 0x%02X)", packet[5]]);
            gInterruptCid = 0;
            gControlCid = 0;
            pp_status(@"Desconectado");
            break;

        case HCI_EVENT_COMMAND_STATUS:
            if (packet[2] != 0) {
                pp_log([NSString stringWithFormat:@"Comando 0x%04X recusado, status 0x%02X", READ_BT_16(packet, 4), packet[2]]);
            }
            break;

        default:
            break;
    }
}

#pragma mark - View controller

@interface PPViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *baselineButton;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *reportLabel;
@property (nonatomic, strong) UILabel *diffLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSMutableString *logText;
@property (nonatomic, assign) BOOL btOpen;
@property (nonatomic, assign) CFTimeInterval lastLogTime;
- (void)appendLog:(NSString *)text;
- (void)reloadDevices;
- (void)showReport:(const uint8_t *)data length:(int)len;
@end

static void pp_log(NSString *text) {
    [gVC appendLog:text];
}

static void pp_status(NSString *text) {
    gVC.statusLabel.text = text;
}

static void pp_devices_changed(void) {
    [gVC reloadDevices];
}

static void pp_report(const uint8_t *data, int len) {
    [gVC showReport:data length:len];
}

@implementation PPViewController

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [b setTitleColor:[UIColor colorWithRed:0.3 green:0.85 blue:1 alpha:1] forState:UIControlStateNormal];
    b.layer.borderColor = [UIColor colorWithRed:0.3 green:0.85 blue:1 alpha:0.6].CGColor;
    b.layer.borderWidth = 1;
    b.layer.cornerRadius = 8;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}

- (UILabel *)monoLabel:(CGFloat)size {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont fontWithName:@"Menlo-Regular" size:size] ?: [UIFont systemFontOfSize:size];
    l.textColor = [UIColor colorWithRed:0.6 green:1 blue:0.6 alpha:1];
    l.numberOfLines = 0;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.5;
    [self.view addSubview:l];
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    gVC = self;
    self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    self.logText = [NSMutableString string];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:20];
    self.statusLabel.text = @"Iniciando BTstack...";
    [self.view addSubview:self.statusLabel];

    self.scanButton = [self button:@"Procurar controles" action:@selector(scanTapped)];
    self.baselineButton = [self button:@"Marcar repouso" action:@selector(baselineTapped)];
    self.saveButton = [self button:@"Salvar log" action:@selector(saveTapped)];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
    self.table.rowHeight = 56;
    [self.view addSubview:self.table];

    self.reportLabel = [self monoLabel:16];
    self.reportLabel.text = @"(nenhum dado ainda)";
    self.diffLabel = [self monoLabel:22];
    self.diffLabel.textColor = [UIColor colorWithRed:1 green:0.85 blue:0.2 alpha:1];
    self.diffLabel.text = @"";

    self.logView = [[UITextView alloc] init];
    self.logView.editable = NO;
    self.logView.backgroundColor = [UIColor blackColor];
    self.logView.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    self.logView.font = [UIFont fontWithName:@"Menlo-Regular" size:12] ?: [UIFont systemFontOfSize:12];
    [self.view addSubview:self.logView];

    [self appendLog:@"PadProbe: conecta controles Bluetooth pelo BTstack."];
    [self appendLog:@"Dica: deixe o Bluetooth do iOS DESLIGADO em Ajustes antes de usar."];
    [self startBTstack];
}

- (void)startBTstack {
    run_loop_init(RUN_LOOP_COCOA);
    if (bt_open()) {
        self.statusLabel.text = @"BTdaemon indisponível";
        [self appendLog:@"Não consegui falar com o BTdaemon. O app precisa estar em /Applications (fora do sandbox) e o pacote BTstack instalado."];
        return;
    }
    self.btOpen = YES;
    bt_register_packet_handler(pp_packet_handler);
    bt_send_cmd(&btstack_set_power_mode, HCI_POWER_ON);
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    CGFloat pad = 12;
    self.statusLabel.frame = CGRectMake(pad, pad, W - 2 * pad, 32);
    CGFloat bw = (W - 4 * pad) / 3.0;
    CGFloat by = 52;
    self.scanButton.frame = CGRectMake(pad, by, bw, 44);
    self.baselineButton.frame = CGRectMake(2 * pad + bw, by, bw, 44);
    self.saveButton.frame = CGRectMake(3 * pad + 2 * bw, by, bw, 44);
    CGFloat y = by + 56;
    CGFloat tableH = MIN(230, H * 0.25);
    self.table.frame = CGRectMake(pad, y, W - 2 * pad, tableH);
    y += tableH + pad;
    self.reportLabel.frame = CGRectMake(pad, y, W - 2 * pad, 60);
    y += 64;
    self.diffLabel.frame = CGRectMake(pad, y, W - 2 * pad, 70);
    y += 76;
    self.logView.frame = CGRectMake(pad, y, W - 2 * pad, H - y - pad);
}

#pragma mark Actions

- (void)scanTapped {
    if (!self.btOpen) return;
    if (gInquiryActive) {
        bt_send_cmd(&hci_inquiry_cancel);
        gInquiryActive = 0;
        self.statusLabel.text = @"Busca cancelada";
        return;
    }
    gInquiryActive = 1;
    self.statusLabel.text = @"Procurando... (coloque o controle em modo de pareamento)";
    [self appendLog:@"Procurando dispositivos por ~12 s"];
    bt_send_cmd(&hci_inquiry, HCI_INQUIRY_LAP, 10, 0);
}

- (void)baselineTapped {
    if (gLastLen == 0) return;
    memcpy(gBaseline, gLastReport, gLastLen);
    gBaselineLen = gLastLen;
    self.diffLabel.text = @"(repouso marcado: aperte um botão)";
    [self appendLog:[NSString stringWithFormat:@"Repouso: %@", [self hex:gBaseline length:gBaselineLen]]];
}

- (void)saveTapped {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"padprobe.txt"];
    NSError *error = nil;
    [self.logText writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    [self appendLog:error ? [NSString stringWithFormat:@"Erro ao salvar: %@", error.localizedDescription]
                          : [NSString stringWithFormat:@"Log salvo em %@", path]];
}

#pragma mark Log / report

- (void)appendLog:(NSString *)text {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [f stringFromDate:[NSDate date]], text];
    [self.logText appendString:line];
    self.logView.text = self.logText;
    if (self.logText.length > 0) {
        [self.logView scrollRangeToVisible:NSMakeRange(self.logText.length - 1, 1)];
    }
}

- (NSString *)hex:(const uint8_t *)data length:(int)len {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < len; i++) {
        [s appendFormat:@"%02X ", data[i]];
    }
    return s;
}

- (void)showReport:(const uint8_t *)data length:(int)len {
    len = MIN(len, 64);
    BOOL changed = (len != gLastLen) || memcmp(data, gLastReport, len) != 0;
    memcpy(gLastReport, data, len);
    gLastLen = len;
    if (gBaselineLen == 0) {
        memcpy(gBaseline, data, len);
        gBaselineLen = len;
    }
    if (!changed) return;

    self.reportLabel.text = [NSString stringWithFormat:@"%d bytes: %@", len, [self hex:data length:len]];

    NSMutableArray *diffs = [NSMutableArray array];
    for (int i = 0; i < len && i < gBaselineLen; i++) {
        if (data[i] != gBaseline[i]) {
            uint8_t x = data[i] ^ gBaseline[i];
            [diffs addObject:[NSString stringWithFormat:@"b%d=%02X (bits %02X)", i, data[i], x]];
        }
    }
    self.diffLabel.text = diffs.count ? [diffs componentsJoinedByString:@"   "] : @"(igual ao repouso)";

    // Registra no log, limitando a ~10 linhas por segundo
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastLogTime > 0.1) {
        self.lastLogTime = now;
        [self appendLog:[NSString stringWithFormat:@"%@| %@", [self hex:data length:len],
                         diffs.count ? [diffs componentsJoinedByString:@" "] : @"repouso"]];
    }
}

#pragma mark Devices table

- (void)reloadDevices {
    [self.table reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return gDeviceCount;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"d"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"d"];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1];
    }
    pp_device_t *d = &gDevices[indexPath.row];
    cell.textLabel.text = d->name[0] ? [NSString stringWithUTF8String:d->name] : @"(sem nome)";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@  ·  toque para conectar",
                                 pp_addr_string(d->addr), pp_cod_string(d->cod)];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.btOpen) return;
    pp_device_t *d = &gDevices[indexPath.row];
    if (gInquiryActive) {
        bt_send_cmd(&hci_inquiry_cancel);
        gInquiryActive = 0;
    }
    BD_ADDR_COPY(gTargetAddr, d->addr);
    gControlCid = 0;
    gInterruptCid = 0;
    self.statusLabel.text = @"Conectando...";
    [self appendLog:[NSString stringWithFormat:@"Conectando a %@ (%s)...", pp_addr_string(d->addr), d->name]];
    bt_send_cmd(&l2cap_create_channel, gTargetAddr, PSM_HID_CONTROL);
}

@end

#pragma mark - App

@interface PPAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation PPAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[PPViewController alloc] init];
    [self.window makeKeyAndVisible];
    application.idleTimerDisabled = YES;
    return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    bt_send_cmd(&btstack_set_power_mode, HCI_POWER_OFF);
    bt_close();
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([PPAppDelegate class]));
    }
}
