import 'dart:developer';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:web_usb/web_usb.dart';

var bootloaderDetectCmd = [
  0xA1,
  0x12,
  0x00,
  0x00,
  0x11,
  0x4D,
  0x43,
  0x55,
  0x20,
  0x49,
  0x53,
  0x50,
  0x20,
  0x26,
  0x20,
  0x57,
  0x43,
  0x48,
  0x2e,
  0x43,
  0x4e
];

var bootloaderIDCmd = [0xA7, 0x02, 0x00, 0x1F, 0x00];

var bootloaderInitCmd = [
  0xA8,
  0x0E,
  0x00,
  0x07,
  0x00,
  0xFF,
  0xFF,
  0xFF,
  0xFF,
  0x03,
  0x00,
  0x00,
  0x00,
  0xFF,
  0x52,
  0x00,
  0x00
];
var bootloaderAddessCmd = [
  0xA3,
  0x1E,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00
];
var bootloaderEraseCmd = [0xA4, 0x01, 0x00, 0x08];
var bootloaderResetCmd = [0xA2, 0x01, 0x00, 0x01]; // if 0x00 not run, 0x01 run

var bootloaderWriteCmd = List.generate(
    64,
    (index) => (index == 0)
        ? 0xA5
        : (index == 1)
            ? 0x3D
            : 0);
var bootloaderVerifyCmd = List.generate(
    64,
    (index) => (index == 0)
        ? 0xA6
        : (index == 1)
            ? 0x3D
            : 0);

var filters = RequestOptionsFilter(vendorId: 0x4348, productId: 0x55e0);

dynamic interfaceNumber;
dynamic endpointOut;
dynamic endpointIn;

int bootloaderDeviceId = 0;
String bootloaderVersion = '';
List<int> bootloaderID = List.empty(growable: true);
List<int> bootloaderMask = List.filled(8, 0);
bool bootloaderUploadReady = false;

Future<dynamic> connectCH55xBootloader() async {
  var device = await usb.requestDevice(RequestOptions(filters: [filters]));
  await device.open();
  if (device.configuration == null) {
    await device.selectConfiguration(1);
  }
  var configurationInterfaces = device.configuration!.interfaces;
  for (var itf in configurationInterfaces) {
    for (var altItf in itf.alternates) {
      if (altItf.interfaceClass == 0xff) {
        interfaceNumber = itf.interfaceNumber;
        for (var ep in altItf.endpoints) {
          if (ep.direction == "out") {
            endpointOut = ep.endpointNumber;
          }
          if (ep.direction == "in") {
            endpointIn = ep.endpointNumber;
          }
        }
      }
    }
  }

  await device.claimInterface(interfaceNumber);

  UsbInTransferResult result;

  await device.transferOut(
      endpointOut, Uint8List.fromList(bootloaderDetectCmd));
  result = await device.transferIn(endpointIn, 64);

  bootloaderDeviceId = result.data.getUint8(4);
  if (result.data.getUint8(5) != 0x11) {
    throw FormatException("MCU family Not support");
  }

  if (![0x51, 0x52, 0x54, 0x58, 0x59].contains(bootloaderDeviceId)) {
    var tmp = bootloaderDeviceId.toRadixString(16);
    throw FormatException("Device not supported 0x$tmp");
  }

  await device.transferOut(endpointOut, Uint8List.fromList(bootloaderIDCmd));
  result = await device.transferIn(endpointIn, 64);

  var major = result.data.getUint8(19);
  var minor = result.data.getUint8(20);
  var build = result.data.getUint8(21);

  bootloaderVersion = "$major.$minor.$build";

  var bootloaderVersionNum = major * 100 + minor * 10 + build;
  if (bootloaderVersionNum < 231 || bootloaderVersionNum > 250) {
    throw FormatException(
        "bootloader Version not supported: $bootloaderVersion");
  }

  bootloaderID = [
    result.data.getUint8(22),
    result.data.getUint8(23),
    result.data.getUint8(24),
    result.data.getUint8(25)
  ];

  log("bootloader Version: $bootloaderVersion, ID: $bootloaderID");

  var idSum =
      (bootloaderID[0] + bootloaderID[1] + bootloaderID[2] + bootloaderID[3]) &
          0xFF;

  for (int i = 0; i < 8; ++i) {
    bootloaderMask[i] = idSum;
  }

  bootloaderMask[7] = (bootloaderMask[7] + bootloaderDeviceId) & 0xFF;

  var maskStr = 'XOR Mask: ';
  for (int i = 0; i < 8; ++i) {
    var hex = bootloaderMask[i].toRadixString(16);
    maskStr = "$maskStr$hex ";
  }
  log(maskStr);
  bootloaderUploadReady = true;
  return device;
}

Future<dynamic> upload(Uint8List hexContent, UsbDevice device) async {
  await device.transferOut(endpointOut, Uint8List.fromList(bootloaderInitCmd));
  UsbInTransferResult result = await device.transferIn(endpointIn, 64);
  log("init data: $result");

  await device.transferOut(endpointOut, Uint8List.fromList(bootloaderIDCmd));
  result = await device.transferIn(endpointIn, 64);

  await device.transferOut(
      endpointOut, Uint8List.fromList(bootloaderAddessCmd));
  result = await device.transferIn(endpointIn, 64);

  await device.transferOut(endpointOut, Uint8List.fromList(bootloaderEraseCmd));
  result = await device.transferIn(endpointIn, 64);

  int writeDataSize, totalPackets, lastPacketSize;

  writeDataSize = hexContent.length;
  log("write $writeDataSize bytes from bin file");

  totalPackets = ((writeDataSize + 55) / 56).toInt();
  lastPacketSize = writeDataSize % 56;
  lastPacketSize = (((lastPacketSize + 7) / 8).toInt() * 8);

  if (lastPacketSize == 0) lastPacketSize = 56;

  int i = 0;
  for (i = 0; i < totalPackets; ++i) {
    int j;
    for (j = 0; j < 56; j++) {
      var index = i * 56 + j;
      if (index > writeDataSize - 1) {
        bootloaderWriteCmd[8 + j] = 0;
      } else {
        bootloaderWriteCmd[8 + j] = hexContent[index];
      }
    }
    for (j = 0; j < 7; ++j) {
      for (var ii = 0; ii < 8; ++ii) {
        bootloaderWriteCmd[8 + j * 8 + ii] ^= bootloaderMask[ii];
      }
    }
    int u16Tmp = i * 56;
    bootloaderWriteCmd[1] = 61 -
        (i < (totalPackets - 1)
            ? 0
            : (56 - lastPacketSize)); //last packet can be smaller
    bootloaderWriteCmd[3] = u16Tmp & 0xFF;
    bootloaderWriteCmd[4] = (u16Tmp >> 8) & 0xFF;

    var length = bootloaderWriteCmd[1] + 3;
    var data = Uint8List.fromList(
        bootloaderWriteCmd.sublist(0, length > 64 ? 64 : length));

    await device.transferOut(endpointOut, data);
    result = await device.transferIn(endpointIn, 64);
    var tmp = i + 1;
    log("flash package $tmp of $totalPackets");
  }

  for (i = 0; i < totalPackets; ++i) {
    int j;
    for (j = 0; j < 56; j++) {
      var index = i * 56 + j;
      if (index > writeDataSize - 1) {
        bootloaderVerifyCmd[8 + j] = 0;
      } else {
        bootloaderVerifyCmd[8 + j] = hexContent[index];
      }
    }
    for (j = 0; j < 7; ++j) {
      for (var ii = 0; ii < 8; ++ii) {
        bootloaderVerifyCmd[8 + j * 8 + ii] ^= bootloaderMask[ii];
      }
    }
    int u16Tmp = i * 56;
    bootloaderVerifyCmd[1] = 61 -
        (i < (totalPackets - 1)
            ? 0
            : (56 - lastPacketSize)); //last packet can be smaller
    bootloaderVerifyCmd[3] = u16Tmp & 0xFF;
    bootloaderVerifyCmd[4] = (u16Tmp >> 8) & 0xFF;

    var length = bootloaderVerifyCmd[1] + 3;
    var data = Uint8List.fromList(
        bootloaderVerifyCmd.sublist(0, length > 64 ? 64 : length));

    await device.transferOut(endpointOut, data);
    result = await device.transferIn(endpointIn, 64);

    if (result.data.getUint8(4) != 0 || result.data.getUint8(5) != 0) {
      throw FormatException('Packet $i does not match');
    } else {
      int tmp = i + 1;
      log('verify package $tmp of $totalPackets');
    }
  }

  await device.transferOut(endpointOut, Uint8List.fromList(bootloaderResetCmd));
  log("flash finished");
}

const cData = 0,
    eof = 1,
    extSagmentAddr = 2,
    startSegmentAddr = 3,
    extLinearAddr = 4,
    startLinearAddr = 5;

const emptyValue = 0xFF;

dynamic parseIntelHex(String data, int bufferSize) {
  //Initialization
  var buf = List.filled(bufferSize, 0),
      bufLength = 0, //Length of data in the buffer
      highAddress = 0, //upper address
      startSegmentAddress = 0,
      startLinearAddress = 0,
      lineNum = 0, //Line number in the Intel Hex string
      pos = 0; //Current position in the Intel Hex string
  const smallestLine = 11;
  while (pos + smallestLine <= data.length) {
    //Parse an entire line
    if (data[pos++] != ":") {
      var nextLine = lineNum + 1;
      throw FormatException("Line $nextLine does not start with a colon (:).");
    } else {
      lineNum++;
    }

    //Number of bytes (hex digit pairs) in the data field
    var dataLength = int.parse(data.substring(pos, pos + 2), radix: 16);
    pos += 2;
    //Get 16-bit address (big-endian)
    var lowAddress = int.parse(data.substring(pos, pos + 4), radix: 16);
    pos += 4;
    //Record type
    var recordType = int.parse(data.substring(pos, pos + 2), radix: 16);
    pos += 2;
    //Data field (hex-encoded string)
    var dataField = data.substring(pos, pos + (dataLength * 2));
    List<int> dataFieldBuf = [];
    int i = 0;
    for (i = 0; i < dataField.length / 2; i++) {
      dataFieldBuf.add(
          int.parse(dataField.substring(i * 2, i * 2 + 2), radix: 16) & 0xFF);
    }
    pos += dataLength * 2;
    //Checksum
    var checksum = int.parse(data.substring(pos, pos + 2), radix: 16);
    pos += 2;
    //Validate checksum
    var calcChecksum =
        (dataLength + (lowAddress >> 8) + lowAddress + recordType) & 0xFF;
    for (var i = 0; i < dataLength; i++) {
      calcChecksum = (calcChecksum + dataFieldBuf[i]) & 0xFF;
    }
    calcChecksum = (0x100 - calcChecksum) & 0xFF;
    if (checksum != calcChecksum) {
      throw FormatException("invalid checksum");
    }
    //Parse the record based on its recordType
    switch (recordType) {
      case cData:
        var absoluteAddress = highAddress + lowAddress;
        //Expand buf, if necessary
        if (absoluteAddress + dataLength >= buf.length) {
          buf.length = (absoluteAddress + dataLength) * 2;
        }
        //Write over skipped bytes with EMPTY_VALUE
        if (absoluteAddress > bufLength) {
          buf.fillRange(bufLength, absoluteAddress, emptyValue);
        }
        //Write the dataFieldBuf to buf
        for (var i = 0; i < dataFieldBuf.length; i++) {
          buf[i + absoluteAddress] = dataFieldBuf[i];
        }
        bufLength = math.max(bufLength, absoluteAddress + dataLength);
        break;
      case eof:
        if (dataLength != 0) {
          throw FormatException("Invalid EOF record on line $lineNum");
        }
        return Uint8List.fromList(buf.sublist(0, bufLength));
      case extSagmentAddr:
        if (dataLength != 2 || lowAddress != 0) {
          throw FormatException(
              "Invalid extended segment address record on line $lineNum");
        }

        highAddress = int.parse(dataField, radix: 16) << 4;
        break;
      case startSegmentAddr:
        if (dataLength != 4 || lowAddress != 0) {
          throw FormatException(
              "Invalid start segment address record on line $lineNum");
        }
        startSegmentAddress = int.parse(dataField, radix: 16);
        break;
      case extLinearAddr:
        if (dataLength != 2 || lowAddress != 0) {
          throw FormatException(
              "Invalid extended linear address record on line $lineNum");
        }

        highAddress = int.parse(dataField, radix: 16) << 16;
        break;
      case startLinearAddr:
        if (dataLength != 4 || lowAddress != 0) {
          throw FormatException(
              "Invalid start linear address record on line $lineNum");
        }
        startLinearAddress = int.parse(dataField, radix: 16);
        break;
      default:
        throw FormatException(
            "Invalid record type ($recordType) on line $lineNum");
    }
    //Advance to the next line
    if (data[pos] == "\r") {
      pos++;
    }
    if (data[pos] == "\n") {
      pos++;
    }
  }
  throw FormatException(
      "Unexpected end of input: missing or invalid EOF record.");
}
