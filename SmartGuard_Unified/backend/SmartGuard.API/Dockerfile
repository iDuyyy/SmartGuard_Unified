# Giai đoạn build mã nguồn
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY ["SmartGuard.API.csproj", "./"]
RUN dotnet restore "SmartGuard.API.csproj"

COPY . .
RUN dotnet publish "SmartGuard.API.csproj" -c Release -o /app/publish

# Giai đoạn chạy ứng dụng
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
COPY --from=build /app/publish .

ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "SmartGuard.API.dll"]