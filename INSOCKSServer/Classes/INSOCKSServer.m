//
//  INSOCKSServer.m
//  INSOCKSServer
//
//  Created by Indragie Karunaratne on 2013-02-16.
//  Copyright (c) 2013 Indragie Karunaratne
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software
// and associated documentation files (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial
// portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
// TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
// CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//

#import "INSOCKSServer.h"
#import <netinet/in.h>
#import <arpa/inet.h>

@interface INSOCKSConnection ()
- (id)initWithSocket:(GCDAsyncSocket *)socket;
@property (nonatomic, assign, readwrite) unsigned long long bytesSent;
@property (nonatomic, assign, readwrite) unsigned long long bytesReceived;
@end

@implementation INSOCKSServer {
	NSMutableArray *_connections;
	GCDAsyncSocket *_socket;
	struct {
		unsigned int didAcceptConnection : 1;
		unsigned int didDisconnectWithError : 1;
	} _delegateFlags;
}
@synthesize connections = _connections;

#pragma mark - Initialization

- (instancetype)initWithPort:(uint16_t)port error:(NSError **)error
{
	if ((self = [super init])) {
		_connections = [NSMutableArray array];
		// Create a master socket to start accepting incoming connections to the proxy
		_socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
		NSError *socketError = nil;
		if (![_socket acceptOnPort:port error:&socketError]) {
			if (error) *error = socketError;
			return nil;
		}
		[[NSNotificationCenter defaultCenter] addObserverForName:INSOCKSConnectionDisconnectedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
			[_connections removeObject:note.object];
		}];
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self disconnectAll];
}

#pragma mark - NSObject

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@:%p host:%@ port:%d>", NSStringFromClass(self.class), self, self.host, self.port];
}

#pragma mark - Public

- (void)disconnectAll
{
	[_connections enumerateObjectsUsingBlock:^(INSOCKSConnection *connection, NSUInteger idx, BOOL *stop) {
		[connection disconnect];
	}];
	[_socket disconnect];
}

#pragma mark - Accessors

- (void)setDelegate:(id<INSOCKSServerDelegate>)delegate
{
	if (_delegate != delegate) {
		_delegate = delegate;
		_delegateFlags.didAcceptConnection = [delegate respondsToSelector:@selector(SOCKSServer:didAcceptConnection:)];
		_delegateFlags.didDisconnectWithError = [delegate respondsToSelector:@selector(SOCKSServer:didDisconnectWithError:)];
	}
}

- (uint16_t)port
{
	return [_socket localPort];
}

- (NSString *)host
{
	return [_socket localHost];
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket
{
	INSOCKSConnection *connection = [[INSOCKSConnection alloc] initWithSocket:newSocket];
	[_connections addObject:connection];
	if (_delegateFlags.didAcceptConnection) {
		[self.delegate SOCKSServer:self didAcceptConnection:connection];
	}
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
	if (_delegateFlags.didDisconnectWithError) {
		[self.delegate SOCKSServer:self didDisconnectWithError:err];
	}
}
@end

/* +----+----------+----------+
 |VER | NMETHODS | METHODS  |
 +----+----------+----------+
 | 1  |    1     | 1 to 255 |
 +----+----------+----------+ */

typedef NS_ENUM(NSInteger, INSOCKS5HandshakePhase) {
	INSOCKS5HandshakePhaseVersion = 5,
	INSOCKS5HandshakePhaseNumberOfAuthenticationMethods,
	INSOCKS5HandshakePhaseAuthenticationMethod,
};

/*
 +----+-----+-------+------+----------+----------+
 |VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
 +----+-----+-------+------+----------+----------+
 | 1  |  1  | X'00' |  1   | Variable |    2     |
 +----+-----+-------+------+----------+----------+
 
 o  VER    protocol version: X'05'
 o  CMD
	o  CONNECT X'01'
	o  BIND X'02'
	o  UDP ASSOCIATE X'03'
 o  RSV    RESERVED
 o  ATYP   address type of following address
	o  IP V4 address: X'01'
	o  DOMAINNAME: X'03'
	o  IP V6 address: X'04'
 o  DST.ADDR       desired destination address
 o  DST.PORT desired destination port in network octet
 order 
 */

typedef NS_ENUM(NSInteger, INSOCKS5RequestPhase) {
	INSOCKS5RequestPhaseHeaderFragment = 10,
	INSOCKS5RequestPhaseAddressType,
	INSOCKS5RequestPhaseIPv4Address,
	INSOCKS5RequestPhaseIPv6Address,
	INSOCKS5RequestPhaseDomainNameLength,
	INSOCKS5RequestPhaseDomainName,
	INSOCKS5RequestPhasePort
};

typedef NS_ENUM(uint8_t, INSOCKS5AddressType) {
	INSOCKS5AddressTypeIPv4 = 0x01,
	INSOCKS5AddressTypeIPv6 = 0x04,
	INSOCKS5AddressTypeDomainName = 0x03
};

typedef NS_ENUM(uint8_t, INSOCKS5Command) {
	INSOCKS5CommandConnect = 0x01,
	INSOCKS5CommandBind = 0x02,
	INSOCKS5CommandUDPAssociate = 0x03
};

/*
 +----+-----+-------+------+----------+----------+
 |VER | REP |  RSV  | ATYP | BND.ADDR | BND.PORT |
 +----+-----+-------+------+----------+----------+
 | 1  |  1  | X'00' |  1   | Variable |    2     |
 +----+-----+-------+------+----------+----------+
 
 o  VER    protocol version: X'05'
 o  REP    Reply field:
	o  X'00' succeeded
	o  X'01' general SOCKS server failure
	o  X'02' connection not allowed by ruleset
	o  X'03' Network unreachable
	o  X'04' Host unreachable
	o  X'05' Connection refused
	o  X'06' TTL expired
	o  X'07' Command not supported
	o  X'08' Address type not supported
	o  X'09' to X'FF' unassigned
	o  RSV    RESERVED
 o  ATYP   address type of following address
	o  IP V4 address: X'01'
	o  DOMAINNAME: X'03'
	o  IP V6 address: X'04'
 o  BND.ADDR       server bound address
 o  BND.PORT       server bound port in network octet order
 */

typedef NS_ENUM(uint8_t, INSOCKS5HandshakeReplyType) {
	INSOCKS5HandshakeReplySucceeded = 0x00,
	INSOCKS5HandshakeReplyGeneralSOCKSServerFailure = 0x01,
	INSOCKS5HandshakeReplyConnectionNotAllowedByRuleset = 0x02,
	INSOCKS5HandshakeReplyNetworkUnreachable = 0x03,
	INSOCKS5HandshakeReplyHostUnreachable = 0x04,
	INSOCKS5HandshakeReplyConnectionRefused = 0x05,
	INSOCKS5HandshakeReplyTTLExpired = 0x06,
	INSOCKS5HandshakeReplyCommandNotSupported = 0x07,
	INSOCKS5HandshakeReplyAddressTypeNotSupported = 0x08
};

/*
 o  X'00' NO AUTHENTICATION REQUIRED
 o  X'01' GSSAPI
 o  X'02' USERNAME/PASSWORD
 o  X'03' to X'7F' IANA ASSIGNED
 o  X'80' to X'FE' RESERVED FOR PRIVATE METHODS
 o  X'FF' NO ACCEPTABLE METHODS
 */

typedef NS_ENUM(uint8_t, INSOCKS5AuthenticationMethod) {
	INSOCKS5AuthenticationNone = 0x00,
	INSOCKS5AuthenticationGSSAPI = 0x01,
	INSOCKS5AuthenticationUsernamePassword = 0x02
};

static NSString * const INSOCKS5ConnectionErrorDomain = @"INSOCKS5ConnectionErrorDomain";
static uint8_t const INSOCKS5HandshakeVersion5 = 0x05;
static NSUInteger const INSOCKS5SuccessfulReplyTag = 100;
NSString* const INSOCKSConnectionDisconnectedNotification = @"INSOCKSConnectionDisconnectedNotification";

@implementation INSOCKSConnection {
	struct {
		unsigned int didDisconnectWithError : 1;
		unsigned int didEncounterErrorDuringSOCKS5Handshake : 1;
		unsigned int TCPConnectionDidFailWithError : 1;
		unsigned int handshakeSucceeded : 1;
		unsigned int didConnectToHost : 1;
	} _delegateFlags;
	GCDAsyncSocket *_clientSocket;
	GCDAsyncSocket *_targetSocket;
	uint8_t _numberOfAuthenticationMethods;
	uint8_t _requestCommandCode;
	NSMutableData *_addressData;
	uint8_t _domainNameLength;
	NSString *_targetHost;
	NSUInteger _targetPort;
	dispatch_queue_t _delegateQueue;
}

#pragma mark - Initialization

- (id)initWithSocket:(GCDAsyncSocket *)socket
{
	if ((self = [super init])) {
		_clientSocket = socket;
		_delegateQueue = dispatch_queue_create("com.indragie.INSOCKSConnection.DelegateQueue", DISPATCH_QUEUE_SERIAL);
		[_clientSocket setDelegate:self delegateQueue:_delegateQueue];
		// Begins the chain reaction that constitutes the SOCKS5 handshake
		[self beginSOCKS5Handshake];
		
	}
	return self;
}

- (void)beginSOCKS5Handshake
{
#ifdef SOCKS_DEBUG_LOGGING
	NSLog(@"Beginning SOCKS5 handshake by requesting version.");
#endif
	[self readDataForSOCKS5Tag:INSOCKS5HandshakePhaseVersion];
}

- (void)disconnect
{
	[_targetSocket disconnect];
	[_clientSocket disconnect];
}

#pragma mark - NSObject

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@:%p host:%@ port:%d bytesSent:%llu bytesReceived:%llu>", NSStringFromClass(self.class), self, self.targetHost, self.targetPort, self.bytesSent, self.bytesReceived];
}

#pragma mark - Accessors

- (void)setDelegate:(id<INSOCKSConnectionDelegate>)delegate
{
	if (_delegate != delegate) {
		_delegate = delegate;
		_delegateFlags.didDisconnectWithError = [delegate respondsToSelector:@selector(SOCKSConnection:didDisconnectWithError:)];
		_delegateFlags.didEncounterErrorDuringSOCKS5Handshake = [delegate respondsToSelector:@selector(SOCKSConnection:didEncounterErrorDuringSOCKS5Handshake:)];
		_delegateFlags.TCPConnectionDidFailWithError = [delegate respondsToSelector:@selector(SOCKSConnection:TCPConnectionDidFailWithError:)];
		_delegateFlags.handshakeSucceeded = [delegate respondsToSelector:@selector(SOCKSConnectionHandshakeSucceeded:)];
		_delegateFlags.didConnectToHost = [delegate respondsToSelector:@selector(SOCKSConnection:didConnectToHost:port:)];
	}
}

- (NSString *)targetHost
{
	return [_targetSocket connectedHost];
}

- (uint16_t)targetPort
{
	return [_targetSocket connectedPort];
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		if (_delegateFlags.didDisconnectWithError) {
			[self.delegate SOCKSConnection:self didDisconnectWithError:err];
		}
	});
	[_clientSocket disconnectAfterReadingAndWriting];
	[_targetSocket disconnectAfterReadingAndWriting];
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
	NSUInteger length = [self.class dataLengthForSOCKS5Tag:tag];
	switch (tag) {
		case INSOCKS5HandshakePhaseVersion:
			[self readSOCKS5VersionFromData:data expectedLength:length];
			break;
		case INSOCKS5HandshakePhaseNumberOfAuthenticationMethods:
			[self readSOCKS5NumberOfAuthenticationMethodsFromData:data expectedLength:length];
			break;
		case INSOCKS5HandshakePhaseAuthenticationMethod:
			[self readSOCKS5AuthenticationMethodsFromData:data];
			break;
		case INSOCKS5RequestPhaseHeaderFragment:
			[self readSOCKS5HeaderFragmentFromData:data expectedLength:length];
			break;
		case INSOCKS5RequestPhaseAddressType:
			[self readSOCKS5AddressTypeFromData:data expectedLength:length];
			break;
		case INSOCKS5RequestPhaseIPv4Address:
			[self readSOCKS5IPv4AddressFromData:data expectedLength:length];
			break;
		case INSOCKS5RequestPhaseIPv6Address:
			[self readSOCKS5IPv6AddressFromData:data expectedLength:length];
			break;
		case INSOCKS5RequestPhaseDomainNameLength:
			[self readSOCKS5DomainNameLengthFromData:data expectedLength:length];
			break;
		case INSOCKS5RequestPhaseDomainName:
			[self readSOCKS5DomainNameFromData:data];
			break;
		case INSOCKS5RequestPhasePort:
			[self readSOCKS5PortFromData:data expectedLength:length];
			break;
		default: {
			// If there's no particular tag, that means it is operating in proxy mode
			if (sock == _clientSocket) {
				[_targetSocket writeData:data withTimeout:-1 tag:0];
				[self incrementBytesSentBy:[data length]];
			} else {
				[_clientSocket writeData:data withTimeout:-1 tag:0];
				[self incrementBytesReceivedBy:[data length]];
			}
			[sock readDataWithTimeout:-1 tag:0];
			break;
		}
	}
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
	// Successfully sent the response to the client, now we can establish a connection
	if (tag == INSOCKS5SuccessfulReplyTag) {
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"Successfully sent server response to SOCKS client");
#endif
		if (_delegateFlags.handshakeSucceeded) {
			[self.delegate SOCKSConnectionHandshakeSucceeded:self];
		}
		_targetSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:_delegateQueue];
		NSError *error = nil;
		if (![_targetSocket connectToHost:_targetHost onPort:_targetPort withTimeout:-1 error:&error]) {
			if (_delegateFlags.TCPConnectionDidFailWithError) {
				[self.delegate SOCKSConnection:self TCPConnectionDidFailWithError:error];
			}
			[_clientSocket disconnectAfterReadingAndWriting];
		} else {
			// Going into proxy mode now, start reading from both sockets and proxying data between them
			[_clientSocket readDataWithTimeout:-1 tag:0];
			[_targetSocket readDataWithTimeout:-1 tag:0];
		}
	}
}

- (void)incrementBytesSentBy:(unsigned long long)length
{
	unsigned long long sent = self.bytesSent;
	sent += length;
	self.bytesSent = sent;
}

- (void)incrementBytesReceivedBy:(unsigned long long)length
{
	unsigned long long received = self.bytesReceived;
	received += length;
	self.bytesReceived = received;
}

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port
{
	if (sock == _targetSocket && _delegateFlags.didConnectToHost) {
		[self.delegate SOCKSConnection:self didConnectToHost:host port:port];
	}
}

- (void)readSOCKS5VersionFromData:(NSData *)data expectedLength:(NSUInteger)length
{
	void(^failureBlock)() = ^{
		[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Invalid SOCKS protocol version."];
	};
	if ([data length] == length) {
		uint8_t version;
		[data getBytes:&version length:length];
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"Received SOCKS protocol version: %d", version);
#endif
		if (version == INSOCKS5HandshakeVersion5) { // SOCKS Protocol Version 5
			[self readDataForSOCKS5Tag:INSOCKS5HandshakePhaseNumberOfAuthenticationMethods];
		} else {
			failureBlock();
		}
	} else {
		failureBlock();
	}
}

- (void)readSOCKS5NumberOfAuthenticationMethodsFromData:(NSData *)data expectedLength:(NSUInteger)length
{
	if ([data length] == length) {
		[data getBytes:&_numberOfAuthenticationMethods length:length];
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"SOCKS client has %d authentication methods", _numberOfAuthenticationMethods);
#endif
		[_clientSocket readDataToLength:_numberOfAuthenticationMethods withTimeout:-1 tag:INSOCKS5HandshakePhaseAuthenticationMethod];
	} else {
		[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Unable to retrieve number of authentication methods."];
	}
}

- (void)readSOCKS5AuthenticationMethodsFromData:(NSData *)data
{
	uint8_t authMethods[_numberOfAuthenticationMethods];
	if ([data length] == sizeof(authMethods)) {
		[data getBytes:&authMethods length:_numberOfAuthenticationMethods];
		BOOL hasSupportedAuthMethod = NO;
		// TODO: Add support for username/password authentication as well
		for (int i = 0; i < sizeof(authMethods); i++) {
#ifdef SOCKS_DEBUG_LOGGING
			NSLog(@"SOCKS client has authentication method: %d", authMethods[i]);
#endif
			if (authMethods[i] == INSOCKS5AuthenticationNone) {
#ifdef SOCKS_DEBUG_LOGGING
				NSLog(@"Selecting anonymous authentication.");
#endif
				hasSupportedAuthMethod = YES;
				break;
			}
		}
		if (hasSupportedAuthMethod) {
			/*
			 +----+--------+
			 |VER | METHOD |
			 +----+--------+
			 | 1  |   1    |
			 +----+--------+
			 */
			NSData *methodSelection = [NSData dataWithBytes:"\x05\x00" length:2];
			// Inform the client of our authentication method selection
			[_clientSocket writeData:methodSelection withTimeout:-1 tag:0];
			[self readDataForSOCKS5Tag:INSOCKS5RequestPhaseHeaderFragment];
		} else {
			[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"No supported authentication method."];
		}
		
	} else {
		[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Could not read authentication methods"];
	}
}

- (void)readSOCKS5HeaderFragmentFromData:(NSData *)data expectedLength:(NSUInteger)length
{
	if ([data length] == length) {
		uint8_t header[length];
		[data getBytes:&header length:length];
		
		uint8_t version = header[0];
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"SOCKS protocol version from request header: %d", version);
#endif
		if (version != INSOCKS5HandshakeVersion5) {
			[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Invalid SOCKS protocol version."];
			return;
		}
		
		_requestCommandCode = header[1];
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"SOCKS command code from request header: %d", _requestCommandCode);
#endif
		// Third byte is just a reserved paramter (0x00);
		[self readDataForSOCKS5Tag:INSOCKS5RequestPhaseAddressType];
	} else {
		[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Could not read request header."];
	}
}

- (void)readSOCKS5AddressTypeFromData:(NSData *)data expectedLength:(NSUInteger)length
{
	if ([data length] == length) {
		_addressData = [NSMutableData dataWithData:data];
		uint8_t addressType;
		[data getBytes:&addressType length:length];
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"SOCKS client address type: %d", addressType);
#endif
		switch (addressType) {
			case INSOCKS5AddressTypeIPv4:
				[self readDataForSOCKS5Tag:INSOCKS5RequestPhaseIPv4Address];
				break;
			case INSOCKS5AddressTypeIPv6:
				[self readDataForSOCKS5Tag:INSOCKS5RequestPhaseIPv6Address];
				break;
			case INSOCKS5AddressTypeDomainName:
				[self readDataForSOCKS5Tag:INSOCKS5RequestPhaseDomainNameLength];
				break;
			default:
				[self refuseConnectionWithReply:INSOCKS5HandshakeReplyAddressTypeNotSupported errorDescription:@"Address type not supported"];
				break;
		}
	} else {
		[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Could not read address type."];
	}
}

- (void)readSOCKS5IPv4AddressFromData:(NSData *)data expectedLength:(NSUInteger)length
{
	if ([data length] == length) {
		uint8_t address[length];
		[data getBytes:&address length:length];
		[_addressData appendBytes:address length:length];
		char ip[INET_ADDRSTRLEN];
		_targetHost = [NSString stringWithCString:inet_ntop(AF_INET, address, ip, sizeof(ip)) encoding:NSUTF8StringEncoding];
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"SOCKS client target host name: %@", _targetHost);
#endif
		[self readDataForSOCKS5Tag:INSOCKS5RequestPhasePort];
	} else {
		[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Could not read IPv4 address."];
	}
}

- (void)readSOCKS5IPv6AddressFromData:(NSData *)data expectedLength:(NSUInteger)length
{
	if ([data length] == length) {
		uint8_t address[length];
		[data getBytes:&address length:length];
		[_addressData appendBytes:address length:length];
		char ip[INET6_ADDRSTRLEN];
		_targetHost = [NSString stringWithCString:inet_ntop(AF_INET6, address, ip, sizeof(ip)) encoding:NSUTF8StringEncoding];
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"SOCKS client target host name: %@", _targetHost);
#endif
		[self readDataForSOCKS5Tag:INSOCKS5RequestPhasePort];
	} else {
		[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Could not read IPv6 address."];
	}
}

- (void)readSOCKS5DomainNameLengthFromData:(NSData *)data expectedLength:(NSUInteger)length
{
	if ([data length] == length) {
		[data getBytes:&_domainNameLength length:length];
		[_addressData appendBytes:&_domainNameLength length:length];
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"SOCKS client domain name length: %d", _domainNameLength);
#endif
		[_clientSocket readDataToLength:_domainNameLength withTimeout:-1 tag:INSOCKS5RequestPhaseDomainName];
	} else {
		[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Could not read domain name length."];
	}
}

- (void)readSOCKS5DomainNameFromData:(NSData *)data
{
	if ([data length] == _domainNameLength) {
		uint8_t domainName[_domainNameLength];
		[data getBytes:&domainName length:_domainNameLength];
		[_addressData appendBytes:domainName length:_domainNameLength];
		_targetHost = [[NSString alloc] initWithBytes:domainName length:_domainNameLength encoding:NSUTF8StringEncoding];
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"SOCKS client target host name: %@", _targetHost);
#endif
		[self readDataForSOCKS5Tag:INSOCKS5RequestPhasePort];
	} else {
		[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Could not read domain name"];
	}
}

- (void)readSOCKS5PortFromData:(NSData *)data expectedLength:(NSUInteger)length
{
	if ([data length] == length) {
		uint8_t port[length];
		[data getBytes:&port length:length];
		[_addressData appendBytes:port length:length];
		_targetPort = (port[0] << 8 | port[1]);
#ifdef SOCKS_DEBUG_LOGGING
		NSLog(@"SOCKS client target port: %lu", _targetPort);
#endif
		
		switch (_requestCommandCode) {
			case INSOCKS5CommandConnect: {
				NSMutableData *responseData = [NSMutableData dataWithData:[self.class replyDataForResponseType:INSOCKS5HandshakeReplySucceeded]];
				[responseData appendData:_addressData];
				[_clientSocket writeData:responseData withTimeout:-1 tag:INSOCKS5SuccessfulReplyTag];
				break;
			}
			case INSOCKS5CommandBind:
			case INSOCKS5CommandUDPAssociate:
				// TODO: Add support for port binding and UDP association
				[self refuseConnectionWithReply:INSOCKS5HandshakeReplyCommandNotSupported errorDescription:@"Command type not supported."];
				break;
			default:
				break;
		}
	} else {
		[self refuseConnectionWithReply:INSOCKS5HandshakeReplyConnectionRefused errorDescription:@"Could not read port."];
	}
}

#pragma mark - Private

- (void)refuseConnectionWithReply:(INSOCKS5HandshakeReplyType)reply errorDescription:(NSString *)description
{
	if (![description length]) return;
	[self sendSOCKS5HandshakeResponseWithType:INSOCKS5HandshakeReplyConnectionRefused];
	[_clientSocket disconnectAfterReadingAndWriting];
	NSError *error = [NSError errorWithDomain:INSOCKS5ConnectionErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : description}];
	if (_delegateFlags.didEncounterErrorDuringSOCKS5Handshake) {
		[self.delegate SOCKSConnection:self didEncounterErrorDuringSOCKS5Handshake:error];
	}
	[self postDisconnectedNotificationWithError:error];
}

- (void)postDisconnectedNotificationWithError:(NSError *)error
{
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:error, @"error", nil];
	[[NSNotificationCenter defaultCenter] postNotificationName:INSOCKSConnectionDisconnectedNotification object:self userInfo:userInfo];
}

+ (NSData *)replyDataForResponseType:(INSOCKS5HandshakeReplyType)type
{
	const unsigned char bytes[3] = {INSOCKS5HandshakeVersion5, type, 0x00}; // 0x00 is a reserved parameter
	return [NSData dataWithBytes:bytes length:3];
}

- (void)sendSOCKS5HandshakeResponseWithType:(INSOCKS5HandshakeReplyType)type
{
	[_clientSocket writeData:[self.class replyDataForResponseType:type] withTimeout:-1 tag:0];
}

+ (NSUInteger)dataLengthForSOCKS5Tag:(NSUInteger)tag
{
	switch (tag) {
		case INSOCKS5HandshakePhaseVersion:
		case INSOCKS5HandshakePhaseNumberOfAuthenticationMethods:
		case INSOCKS5RequestPhaseAddressType:
		case INSOCKS5RequestPhaseDomainNameLength:
			return 1;
		case INSOCKS5RequestPhaseHeaderFragment:
			return 3;
		case INSOCKS5RequestPhaseIPv4Address:
			return 4;
		case INSOCKS5RequestPhaseIPv6Address:
			return 16;
		case INSOCKS5RequestPhasePort:
			return 2;
		default:
			return 0;
			break;
	}
}

- (void)readDataForSOCKS5Tag:(NSInteger)tag
{
	NSUInteger dataLength = [self.class dataLengthForSOCKS5Tag:tag];
	if (dataLength) {
		[_clientSocket readDataToLength:dataLength withTimeout:-1 tag:tag];
	}
}
@end
